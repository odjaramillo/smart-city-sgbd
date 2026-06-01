-- ==============================================================================
-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)
-- MATERIA:  Gestión de Datos — Prof. Armen Djenanian
-- FASE 2:   Pipeline de Ingesta Idempotente (Estrategia ELT)
-- PLATAFORMA: Supabase (PostgreSQL 15+)
--
-- NOTAS DE ARQUITECTURA (embebidas como comentarios):
--
--   Estrategia ELT (no ETL):
--     La transformación ocurre DENTRO de la base de datos, no en n8n. Esto es
--     deliberado: PostgreSQL es un motor de conjuntos extremadamente eficiente;
--     mover datos a n8n para transformarlos y luego devolverlos sería un
--     antipatrón de latencia y costo de red. El patrón es:
--       n8n → INSERT en staging_eventos (EL)
--       PostgreSQL → sp_reconciliar_interrupciones (T)
--       Power BI → SELECT sobre vistas analíticas (L)
--
--   Idempotencia:
--     - El SP solo procesa eventos con procesado = FALSE.
--     - Cada lote tiene un id_lote_procesamiento único generado por secuencia.
--     - Antes de insertar en fact_interrupciones, verifica que no exista ya un
--       hecho con el mismo id_medidor + timestamp_inicio (duplicado exacto).
--     - Antes de desviar a err_telemetria, verifica que el mismo evento no haya
--       sido ya registrado como error en un lote anterior.
--     - El UPDATE de staging_eventos.procesado = TRUE ocurre al final, dentro
--       de la misma transacción. Si algo falla, todo hace ROLLBACK.
--     - Ejecutar el SP 10 veces con los mismos parámetros produce exactamente
--       el mismo resultado que ejecutarlo 1 vez.
--
--   Regla IEEE 1366 — Interrupciones menores a 5 minutos:
--     El estándar establece que eventos con duración < 5 minutos son
--     "momentary interruptions" (macro-caídas transitorias) y NO deben
--     contabilizarse para SAIDI/SAIFI rutinario. El SP aplica este filtro
--     después de calcular la duración del par OUTAGE→RESTORATION. Los eventos
--     transitorios se cuentan en ctrl_lotes_procesamiento para auditoría pero
--     no generan filas en fact_interrupciones.
--
--   Manejo de huérfanos:
--     - RESTORATION sin OUTAGE previa: se desvía a err_telemetria con motivo
--       'RESTAURACION_HUERFANA'. Esto puede ocurrir si el OUTAGE correspondiente
--       se perdió en tránsito o si el medidor se reinició.
--     - OUTAGE sin RESTORATION: se deja en staging con procesado = FALSE para
--       que sea emparejado en un lote futuro cuando llegue la restauración.
--       No es un error, es un evento abierto.
--     - OUTAGE consecutiva (dos OUTAGE seguidas sin RESTORATION intermedia):
--       la primera OUTAGE no tiene par → se desvía a err_telemetria como
--       'OUTAGE_DUPLICADA'. Indica posible error de firmware del medidor.
-- ==============================================================================
-- ==============================================================================
-- Fix H-6: REGISTRO AUTONOMO DE LOTES FALLIDOS
-- ==============================================================================
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE OR REPLACE FUNCTION fn_log_lote_fallido(p_lote_id INTEGER, p_error TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_conn TEXT := COALESCE(
        current_setting('app.dblink_conn', true),
        'dbname=' || current_database()
    );
BEGIN
    PERFORM dblink(v_conn, format(
        'INSERT INTO ctrl_lotes_procesamiento
            (id_lote, fecha_inicio, fecha_fin, estado, fecha_ejecucion)
         VALUES (%L::int, ''-infinity''::timestamptz, ''infinity''::timestamptz,
                 ''FALLIDO'', now())
         ON CONFLICT (id_lote) DO UPDATE SET estado = ''FALLIDO''',
        p_lote_id));
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'fn_log_lote_fallido: registro autonomo no disponible (%). Configure dblink/app.dblink_conn.', SQLERRM;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_reconciliar_interrupciones(
    p_fecha_inicio TIMESTAMPTZ DEFAULT NULL,
    p_fecha_fin    TIMESTAMPTZ DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_lote_id            INTEGER;
    v_total_eventos      INTEGER := 0;
    v_total_hechos       INTEGER := 0;
    v_total_huerfanos    INTEGER := 0;
    v_total_transitorios INTEGER := 0;
    v_inicio_ejecucion   TIMESTAMPTZ;
    v_fin_ejecucion      TIMESTAMPTZ;
    v_rec                RECORD;
    v_duracion           NUMERIC(10,2);
    v_sk_fecha           BIGINT;
    v_sk_tiempo          BIGINT;
    v_sk_red             BIGINT;
    v_sk_geo             BIGINT;
    v_sk_clientes        BIGINT;
    v_existe_hecho       BOOLEAN;
    v_existe_error       BOOLEAN;
    v_sk_tipo_evento     BIGINT;
BEGIN
    -- =====================================================================
    -- BLOQUE 0: Inicialización del lote
    -- =====================================================================
    v_inicio_ejecucion := clock_timestamp();
    v_lote_id := nextval('seq_lote_procesamiento');
    INSERT INTO ctrl_lotes_procesamiento (
        id_lote, fecha_inicio, fecha_fin, estado
    ) VALUES (
        v_lote_id,
        COALESCE(p_fecha_inicio, '-infinity'::TIMESTAMPTZ),
        COALESCE(p_fecha_fin,    'infinity'::TIMESTAMPTZ),
        'INICIADO'
    );

    -- =====================================================================
    -- BLOQUE 1: Detección y desvío de RESTAURACIONES HUÉRFANAS
    -- =====================================================================
    DROP TABLE IF EXISTS tmp_huerfanos;
    CREATE TEMP TABLE tmp_huerfanos AS
    WITH eventos_ord AS (
        SELECT
            id_evento,
            id_medidor,
            timestamp_evento,
            tipo_evento,
            LAG(tipo_evento) OVER w AS tipo_anterior,
            LAG(id_evento)   OVER w AS id_anterior
        FROM staging_eventos
        WHERE procesado = FALSE
          AND (p_fecha_inicio IS NULL OR timestamp_evento >= p_fecha_inicio)
          AND (p_fecha_fin    IS NULL OR timestamp_evento <= p_fecha_fin)
        WINDOW w AS (PARTITION BY id_medidor ORDER BY timestamp_evento, id_evento)
    )
    SELECT id_evento, id_medidor, timestamp_evento, tipo_evento,
           CASE
               WHEN tipo_anterior IS NULL
                    AND tipo_evento = 'POWER_RESTORATION'
                    THEN 'RESTAURACION_HUERFANA: no existe OUTAGE previa para este medidor'
               WHEN tipo_anterior = 'POWER_RESTORATION'
                    AND tipo_evento = 'POWER_RESTORATION'
                    THEN 'RESTAURACION_HUERFANA: restauración consecutiva sin OUTAGE intermedia'
           END AS motivo
    FROM eventos_ord
    WHERE tipo_evento = 'POWER_RESTORATION'
      AND (tipo_anterior IS NULL OR tipo_anterior = 'POWER_RESTORATION');

    INSERT INTO err_telemetria (
        id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
        motivo_error, id_lote_procesamiento
    )
    SELECT
        h.id_evento, h.id_medidor, h.timestamp_evento, h.tipo_evento,
        h.motivo, v_lote_id
    FROM tmp_huerfanos h
    WHERE NOT EXISTS (
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = h.id_evento
    );
    GET DIAGNOSTICS v_total_huerfanos = ROW_COUNT;

    UPDATE staging_eventos se
    SET procesado = TRUE
    FROM tmp_huerfanos h
    WHERE se.id_evento = h.id_evento;

    -- =====================================================================
    -- BLOQUE 2: Emparejamiento OUTAGE → RESTORATION
    -- =====================================================================
    FOR v_rec IN
        WITH eventos_ord AS (
            SELECT
                id_evento,
                id_medidor,
                timestamp_evento,
                tipo_evento,
                LEAD(tipo_evento)      OVER w AS next_tipo,
                LEAD(id_evento)        OVER w AS next_id,
                LEAD(timestamp_evento) OVER w AS next_ts
            FROM staging_eventos
            WHERE procesado = FALSE
              AND (p_fecha_inicio IS NULL OR timestamp_evento >= p_fecha_inicio)
              AND (p_fecha_fin    IS NULL OR timestamp_evento <= p_fecha_fin)
            WINDOW w AS (PARTITION BY id_medidor ORDER BY timestamp_evento, id_evento)
        )
        SELECT
            o.id_medidor,
            ROW_NUMBER() OVER (PARTITION BY o.id_medidor
                               ORDER BY o.timestamp_evento, o.id_evento) AS num_par,
            CASE WHEN o.next_tipo = 'POWER_RESTORATION' THEN 2 ELSE 1 END AS eventos_en_par,
            o.id_evento        AS id_outage,
            o.timestamp_evento AS ts_outage,
            o.tipo_evento      AS tipo_evento_outage,
            CASE WHEN o.next_tipo = 'POWER_RESTORATION' THEN o.next_id END AS id_restoration,
            CASE WHEN o.next_tipo = 'POWER_RESTORATION' THEN o.next_ts END AS ts_restoration,
            CASE
                WHEN o.next_tipo = 'POWER_RESTORATION' THEN 'PAR_VALIDO'
                WHEN o.next_tipo = 'POWER_OUTAGE'      THEN 'DOBLE_OUTAGE'
                WHEN o.next_tipo IS NULL               THEN 'OUTAGE_ABIERTO'
                ELSE 'ERROR_DESCONOCIDO'
            END AS clasificacion
        FROM eventos_ord o
        WHERE o.tipo_evento = 'POWER_OUTAGE'
        ORDER BY o.id_medidor, num_par
    LOOP
        v_total_eventos := v_total_eventos + v_rec.eventos_en_par;

        IF v_rec.clasificacion = 'PAR_VALIDO' THEN
            v_duracion := EXTRACT(EPOCH FROM (v_rec.ts_restoration - v_rec.ts_outage)) / 60.0;

            IF v_duracion < 5.0 THEN
                v_total_transitorios := v_total_transitorios + 1;
                UPDATE staging_eventos
                SET procesado = TRUE
                WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);
                CONTINUE;
            END IF;

            SELECT EXISTS (
                SELECT 1 FROM fact_interrupciones
                WHERE id_medidor = v_rec.id_medidor
                  AND timestamp_inicio = v_rec.ts_outage
            ) INTO v_existe_hecho;

            IF v_existe_hecho THEN
                UPDATE staging_eventos
                SET procesado = TRUE
                WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);
                CONTINUE;
            END IF;

            -- SK de fecha (dim_fecha — granularidad diaria)
            SELECT sk_fecha INTO v_sk_fecha
            FROM dim_fecha
            WHERE fecha = v_rec.ts_outage::DATE;

            -- SK de tiempo (dim_tiempo — granularidad horaria, 24 filas)
            SELECT sk_tiempo INTO v_sk_tiempo
            FROM dim_tiempo
            WHERE hora = EXTRACT(HOUR FROM v_rec.ts_outage)::SMALLINT;

            -- SK de red eléctrica
            SELECT sk_red_electrica INTO v_sk_red
            FROM dim_red_electrica
            WHERE id_medidor_origen = v_rec.id_medidor
              AND fecha_inicio <= v_rec.ts_outage
              AND (fecha_fin IS NULL OR fecha_fin > v_rec.ts_outage)
            ORDER BY fecha_inicio DESC
            LIMIT 1;

            IF v_sk_red IS NULL THEN
                SELECT sk_geografia_urbana INTO v_sk_geo
                FROM dim_geografia_urbana
                WHERE sector_urbano = 'SECTOR_DESCONOCIDO'
                LIMIT 1;

                IF v_sk_geo IS NULL THEN
                    INSERT INTO dim_geografia_urbana (sector_urbano, distrito)
                    VALUES ('SECTOR_DESCONOCIDO', 'DISTRITO_DESCONOCIDO')
                    RETURNING sk_geografia_urbana INTO v_sk_geo;
                END IF;

                INSERT INTO dim_red_electrica (
                    id_medidor, id_medidor_origen, codigo_medidor,
                    transformador, circuito, subestacion,
                    sk_geografia_urbana,
                    fecha_inicio, activo_bool
                ) VALUES (
                    v_rec.id_medidor,
                    v_rec.id_medidor,
                    'MED-' || v_rec.id_medidor::TEXT,
                    'TRANSFORMADOR_DESCONOCIDO',
                    'CIRCUITO_DESCONOCIDO',
                    'SUBESTACION_DESCONOCIDA',
                    v_sk_geo,
                    v_rec.ts_outage - INTERVAL '1 day',
                    TRUE
                )
                RETURNING sk_red_electrica INTO v_sk_red;
            END IF;

            -- SK de geografía derivada del activo de red (Fix H-4)
            SELECT sk_geografia_urbana INTO v_sk_geo
            FROM dim_red_electrica
            WHERE sk_red_electrica = v_sk_red;

            IF v_sk_geo IS NULL THEN
                SELECT sk_geografia_urbana INTO v_sk_geo
                FROM dim_geografia_urbana
                WHERE sector_urbano = 'SECTOR_DESCONOCIDO'
                LIMIT 1;

                IF v_sk_geo IS NULL THEN
                    INSERT INTO dim_geografia_urbana (sector_urbano, distrito)
                    VALUES ('SECTOR_DESCONOCIDO', 'DISTRITO_DESCONOCIDO')
                    RETURNING sk_geografia_urbana INTO v_sk_geo;
                END IF;
            END IF;

            -- SK de clientes
            SELECT sk_clientes INTO v_sk_clientes
            FROM dim_clientes_inventario
            WHERE fecha_inicio <= v_rec.ts_outage
              AND (fecha_fin IS NULL OR fecha_fin > v_rec.ts_outage)
            ORDER BY fecha_inicio DESC
            LIMIT 1;

            IF v_sk_clientes IS NULL THEN
                INSERT INTO dim_clientes_inventario (
                    total_clientes_servidos, fecha_inicio, activo_bool
                ) VALUES (
                    1,
                    '2020-01-01 00:00:00+00'::TIMESTAMPTZ,
                    TRUE
                )
                RETURNING sk_clientes INTO v_sk_clientes;
            END IF;

            -- SK de tipo de evento
            SELECT sk_tipo_evento INTO v_sk_tipo_evento
            FROM dim_tipo_evento
            WHERE codigo_evento = v_rec.tipo_evento_outage;

            IF v_sk_tipo_evento IS NULL THEN
                v_sk_tipo_evento := -1;
                INSERT INTO err_telemetria (
                    id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                    tipo_error, motivo_error, id_lote_procesamiento, detalle_tecnico
                ) VALUES (
                    v_rec.id_outage,
                    v_rec.id_medidor,
                    v_rec.ts_outage,
                    COALESCE(v_rec.tipo_evento_outage, 'UNKNOWN'),
                    'EVENTO_DESCONOCIDO',
                    'Tipo de evento ''' || COALESCE(v_rec.tipo_evento_outage, 'NULL') || ''' no existe en dim_tipo_evento',
                    v_lote_id,
                    'Se inserta con sk_tipo_evento = -1 (UNKNOWN). Verificar dim_tipo_evento.'
                ) ON CONFLICT DO NOTHING;
            END IF;

            INSERT INTO fact_interrupciones (
                sk_fecha, sk_tiempo, sk_red_electrica, sk_geografia_urbana,
                sk_clientes, sk_tipo_evento,
                id_medidor, timestamp_inicio, timestamp_fin,
                duracion_minutos, clientes_afectados,
                id_lote_procesamiento
            ) VALUES (
                v_sk_fecha,
                v_sk_tiempo,
                v_sk_red,
                v_sk_geo,
                v_sk_clientes,
                v_sk_tipo_evento,
                v_rec.id_medidor,
                v_rec.ts_outage,
                v_rec.ts_restoration,
                v_duracion,
                1,
                v_lote_id
            );
            v_total_hechos := v_total_hechos + 1;

            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);

        ELSIF v_rec.clasificacion = 'OUTAGE_ABIERTO' THEN
            NULL;

        ELSIF v_rec.clasificacion = 'RESTAURACION_SOLITARIA' THEN
            INSERT INTO err_telemetria (
                id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                motivo_error, id_lote_procesamiento
            ) VALUES (
                v_rec.id_restoration,
                v_rec.id_medidor,
                v_rec.ts_restoration,
                'POWER_RESTORATION',
                'RESTAURACION_SOLITARIA: evento escapado del filtro de huérfanos',
                v_lote_id
            ) ON CONFLICT DO NOTHING;
            v_total_huerfanos := v_total_huerfanos + 1;
            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento = v_rec.id_restoration;

        ELSIF v_rec.clasificacion = 'DOBLE_OUTAGE' THEN
            INSERT INTO err_telemetria (
                id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                motivo_error, id_lote_procesamiento, detalle_tecnico
            ) VALUES (
                v_rec.id_outage,
                v_rec.id_medidor,
                v_rec.ts_outage,
                'POWER_OUTAGE',
                'OUTAGE_DUPLICADA: dos eventos POWER_OUTAGE consecutivos sin RESTORATION intermedia',
                v_lote_id,
                'Posible error de firmware en el medidor o duplicación en la ingesta n8n.'
            ) ON CONFLICT DO NOTHING;
            v_total_huerfanos := v_total_huerfanos + 1;
            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento = v_rec.id_outage;

        ELSIF v_rec.clasificacion = 'DOBLE_RESTAURACION' THEN
            INSERT INTO err_telemetria (
                id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                motivo_error, id_lote_procesamiento
            ) VALUES (
                v_rec.id_restoration,
                v_rec.id_medidor,
                v_rec.ts_restoration,
                'POWER_RESTORATION',
                'RESTAURACION_DUPLICADA: dos eventos POWER_RESTORATION consecutivos',
                v_lote_id
            ) ON CONFLICT DO NOTHING;
            v_total_huerfanos := v_total_huerfanos + 1;
            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento = v_rec.id_restoration;
        END IF;
    END LOOP;

    -- =====================================================================
    -- BLOQUE 3: Finalización y registro de auditoría
    -- =====================================================================
    v_fin_ejecucion := clock_timestamp();
    UPDATE ctrl_lotes_procesamiento
    SET total_eventos      = v_total_eventos,
        total_hechos       = v_total_hechos,
        total_huerfanos    = v_total_huerfanos,
        total_transitorios = v_total_transitorios,
        estado             = 'COMPLETADO',
        duracion_segundos  = EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))
    WHERE id_lote = v_lote_id;

    RAISE NOTICE 'Lote % completado: % eventos, % hechos, % huérfanos, % transitorios (<5 min) en % segundos.',
        v_lote_id, v_total_eventos, v_total_hechos, v_total_huerfanos,
        v_total_transitorios,
        ROUND(EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))::NUMERIC, 2);

EXCEPTION
    WHEN OTHERS THEN
        PERFORM fn_log_lote_fallido(v_lote_id, SQLERRM);
        RAISE;
END;
$$;

-- =============================================================================
-- WRAPPER: fn_reconciliar_interrupciones
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_reconciliar_interrupciones(
    p_fecha_inicio TIMESTAMPTZ DEFAULT NULL,
    p_fecha_fin    TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_resultado JSONB;
    v_lote_id  INTEGER;
BEGIN
    CALL sp_reconciliar_interrupciones(p_fecha_inicio, p_fecha_fin);
    v_lote_id := currval('seq_lote_procesamiento');
    SELECT jsonb_build_object(
        'lote_id',           id_lote,
        'estado',            estado,
        'total_eventos',     total_eventos,
        'total_hechos',      total_hechos,
        'total_huerfanos',   total_huerfanos,
        'total_transitorios', total_transitorios,
        'duracion_segundos',  duracion_segundos,
        'fecha_ejecucion',    fecha_ejecucion
    ) INTO v_resultado
    FROM ctrl_lotes_procesamiento
    WHERE id_lote = v_lote_id;
    RETURN v_resultado;
END;
$$;

COMMENT ON PROCEDURE sp_reconciliar_interrupciones IS
'SP idempotente de reconciliación ELT. Empareja POWER_OUTAGE con POWER_RESTORATION,
aplica filtro IEEE 1366 (< 5 min), desvía huérfanos a err_telemetria.';
COMMENT ON FUNCTION fn_reconciliar_interrupciones IS
'Wrapper JSON para invocación desde n8n. Retorna resumen del lote procesado.';

-- =============================================================================
-- SP3: sp_reconciliar_telemetria
-- =============================================================================
CREATE OR REPLACE PROCEDURE sp_reconciliar_telemetria(
    p_fecha_inicio TIMESTAMPTZ DEFAULT NULL,
    p_fecha_fin    TIMESTAMPTZ DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_lote_id                 INTEGER;
    v_total_lecturas          INTEGER := 0;
    v_total_hechos            INTEGER := 0;
    v_total_errores           INTEGER := 0;
    v_total_medidor_inactivo  INTEGER := 0;
    v_total_voltage_out_range INTEGER := 0;
    v_total_consumo_negativo  INTEGER := 0;
    v_inicio_ejecucion        TIMESTAMPTZ;
    v_fin_ejecucion           TIMESTAMPTZ;
    C_VOLTAGE_MIN             NUMERIC(8,2) := 0;
    C_VOLTAGE_MAX             NUMERIC(8,2) := 1000;
    C_VOLTAGE_NORMAL_MIN      NUMERIC(8,2) := 180;
    C_VOLTAGE_NORMAL_MAX      NUMERIC(8,2) := 260;
BEGIN
    -- =====================================================================
    -- BLOQUE 0: Inicialización del lote
    -- =====================================================================
    v_inicio_ejecucion := clock_timestamp();
    v_lote_id := nextval('seq_lote_procesamiento');
    INSERT INTO ctrl_lotes_procesamiento (
        id_lote, fecha_inicio, fecha_fin, estado
    ) VALUES (
        v_lote_id,
        COALESCE(p_fecha_inicio, '-infinity'::TIMESTAMPTZ),
        COALESCE(p_fecha_fin,    'infinity'::TIMESTAMPTZ),
        'INICIADO'
    );

    -- =====================================================================
    -- BLOQUE 1: Validación y desvío de errores
    -- =====================================================================
    SELECT COUNT(*) INTO v_total_lecturas
    FROM staging_telemetria st
    WHERE st.procesado = FALSE
      AND (p_fecha_inicio IS NULL OR st.timestamp_lectura >= p_fecha_inicio)
      AND (p_fecha_fin    IS NULL OR st.timestamp_lectura <= p_fecha_fin);

    -- Medidores inactivos
    DROP TABLE IF EXISTS tmp_medidores_inactivos;
    CREATE TEMP TABLE tmp_medidores_inactivos AS
        SELECT DISTINCT
            st.id_staging,
            st.id_medidor,
            st.timestamp_lectura,
            st.consumo_wh,
            st.voltaje,
            st.tipo_lectura,
            'MEDIDOR_INACTIVO: medidor no existe en dim_red_electrica o no está activo para esta fecha' AS motivo
        FROM staging_telemetria st
        WHERE st.procesado = FALSE
          AND (p_fecha_inicio IS NULL OR st.timestamp_lectura >= p_fecha_inicio)
          AND (p_fecha_fin    IS NULL OR st.timestamp_lectura <= p_fecha_fin)
          AND NOT EXISTS (
              SELECT 1 FROM dim_red_electrica dre
              WHERE dre.id_medidor_origen = st.id_medidor
                AND dre.fecha_inicio <= st.timestamp_lectura
                AND (dre.fecha_fin IS NULL OR dre.fecha_fin > st.timestamp_lectura)
                AND dre.activo_bool = TRUE
          );

    INSERT INTO err_telemetria (
        id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
        tipo_error, motivo_error, detalle_tecnico, id_lote_procesamiento
    )
    SELECT
        mi.id_staging, mi.id_medidor, mi.timestamp_lectura, mi.tipo_lectura,
        'MEDIDOR_INACTIVO', mi.motivo,
        jsonb_build_object(
            'consumo_wh', mi.consumo_wh,
            'voltaje', mi.voltaje,
            'tipo_lectura', mi.tipo_lectura,
            'bloque', 'BLOQUE_1'
        )::TEXT,
        v_lote_id
    FROM tmp_medidores_inactivos mi
    WHERE NOT EXISTS (
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = mi.id_staging
          AND e.tipo_error = 'MEDIDOR_INACTIVO'
    );
    GET DIAGNOSTICS v_total_medidor_inactivo = ROW_COUNT;
    v_total_errores := v_total_errores + v_total_medidor_inactivo;

    UPDATE staging_telemetria st
    SET procesado = TRUE
    FROM tmp_medidores_inactivos mi
    WHERE st.id_staging = mi.id_staging;

    -- Voltaje fuera de rango
    WITH voltajes_invalidos AS (
        SELECT DISTINCT
            st.id_staging, st.id_medidor, st.timestamp_lectura,
            st.consumo_wh, st.voltaje, st.tipo_lectura,
            CASE
                WHEN st.voltaje < C_VOLTAGE_MIN OR st.voltaje > C_VOLTAGE_MAX
                    THEN 'VOLTAGE_OUT_OF_RANGE: voltaje fuera del rango aceptable 0-1000V'
                WHEN st.voltaje < C_VOLTAGE_NORMAL_MIN OR st.voltaje > C_VOLTAGE_NORMAL_MAX
                    THEN 'VOLTAGE_OUT_OF_RANGE: voltaje fuera del rango normal 180-260V (posible fluctuación)'
            END AS motivo
        FROM staging_telemetria st
        WHERE st.procesado = FALSE
          AND (p_fecha_inicio IS NULL OR st.timestamp_lectura >= p_fecha_inicio)
          AND (p_fecha_fin    IS NULL OR st.timestamp_lectura <= p_fecha_fin)
          AND (st.voltaje < C_VOLTAGE_MIN OR st.voltaje > C_VOLTAGE_MAX
               OR st.voltaje < C_VOLTAGE_NORMAL_MIN OR st.voltaje > C_VOLTAGE_NORMAL_MAX)
          AND EXISTS (
              SELECT 1 FROM dim_red_electrica dre
              WHERE dre.id_medidor_origen = st.id_medidor
                AND dre.fecha_inicio <= st.timestamp_lectura
                AND (dre.fecha_fin IS NULL OR dre.fecha_fin > st.timestamp_lectura)
                AND dre.activo_bool = TRUE
          )
    )
    INSERT INTO err_telemetria (
        id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
        tipo_error, motivo_error, detalle_tecnico, id_lote_procesamiento
    )
    SELECT
        vi.id_staging, vi.id_medidor, vi.timestamp_lectura, vi.tipo_lectura,
        'VOLTAGE_OUT_OF_RANGE', vi.motivo,
        jsonb_build_object(
            'voltaje', vi.voltaje,
            'rango_aceptable', format('[%s, %s]', C_VOLTAGE_MIN, C_VOLTAGE_MAX),
            'rango_normal', format('[%s, %s]', C_VOLTAGE_NORMAL_MIN, C_VOLTAGE_NORMAL_MAX),
            'bloque', 'BLOQUE_1'
        )::TEXT,
        v_lote_id
    FROM voltajes_invalidos vi
    WHERE NOT EXISTS (
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = vi.id_staging
          AND e.tipo_error = 'VOLTAGE_OUT_OF_RANGE'
    );
    GET DIAGNOSTICS v_total_voltage_out_range = ROW_COUNT;
    v_total_errores := v_total_errores + v_total_voltage_out_range;

    -- Consumo negativo
    DROP TABLE IF EXISTS tmp_consumo_negativo;
    CREATE TEMP TABLE tmp_consumo_negativo AS
        SELECT DISTINCT
            st.id_staging, st.id_medidor, st.timestamp_lectura,
            st.consumo_wh, st.voltaje, st.tipo_lectura,
            'CONSUMO_NEGATIVO: consumo_wh no puede ser negativo' AS motivo
        FROM staging_telemetria st
        WHERE st.procesado = FALSE
          AND (p_fecha_inicio IS NULL OR st.timestamp_lectura >= p_fecha_inicio)
          AND (p_fecha_fin    IS NULL OR st.timestamp_lectura <= p_fecha_fin)
          AND st.consumo_wh < 0
          AND EXISTS (
              SELECT 1 FROM dim_red_electrica dre
              WHERE dre.id_medidor_origen = st.id_medidor
                AND dre.fecha_inicio <= st.timestamp_lectura
                AND (dre.fecha_fin IS NULL OR dre.fecha_fin > st.timestamp_lectura)
                AND dre.activo_bool = TRUE
          );

    INSERT INTO err_telemetria (
        id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
        tipo_error, motivo_error, detalle_tecnico, id_lote_procesamiento
    )
    SELECT
        cn.id_staging, cn.id_medidor, cn.timestamp_lectura, cn.tipo_lectura,
        'CONSUMO_NEGATIVO', cn.motivo,
        jsonb_build_object(
            'consumo_wh', cn.consumo_wh,
            'voltaje', cn.voltaje,
            'bloque', 'BLOQUE_1'
        )::TEXT,
        v_lote_id
    FROM tmp_consumo_negativo cn
    WHERE NOT EXISTS (
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = cn.id_staging
          AND e.tipo_error = 'CONSUMO_NEGATIVO'
    );
    GET DIAGNOSTICS v_total_consumo_negativo = ROW_COUNT;
    v_total_errores := v_total_errores + v_total_consumo_negativo;

    UPDATE staging_telemetria st
    SET procesado = TRUE
    FROM tmp_consumo_negativo cn
    WHERE st.id_staging = cn.id_staging;

    -- =====================================================================
    -- BLOQUE 2: Bulk INSERT con conversión de unidades y resolución de SKs
    -- =====================================================================
    INSERT INTO fact_telemetria (
        sk_fecha, sk_tiempo, sk_red_electrica, sk_geografia_urbana,
        sk_tipo_evento, timestamp_lectura, consumo_kwh, voltaje,
        id_lote_procesamiento
    )
    SELECT
        df.sk_fecha,
        dt.sk_tiempo,
        dre.sk_red_electrica,
        COALESCE(dre.sk_geografia_urbana, -1),
        COALESCE(dte.sk_tipo_evento, -1),
        DATE_TRUNC('hour', st.timestamp_lectura),
        st.consumo_wh / 1000.0,
        st.voltaje,
        v_lote_id
    FROM staging_telemetria st
    JOIN dim_fecha df
        ON df.fecha = st.timestamp_lectura::DATE
    JOIN dim_tiempo dt
        ON dt.hora = EXTRACT(HOUR FROM st.timestamp_lectura)::SMALLINT
    JOIN dim_red_electrica dre
        ON dre.id_medidor_origen = st.id_medidor
        AND dre.fecha_inicio <= st.timestamp_lectura
        AND (dre.fecha_fin IS NULL OR dre.fecha_fin > st.timestamp_lectura)
        AND dre.activo_bool = TRUE
    LEFT JOIN dim_tipo_evento dte
        ON dte.codigo_evento = st.tipo_lectura
    WHERE st.procesado = FALSE
      AND (p_fecha_inicio IS NULL OR st.timestamp_lectura >= p_fecha_inicio)
      AND (p_fecha_fin    IS NULL OR st.timestamp_lectura <= p_fecha_fin)
      AND st.voltaje >= C_VOLTAGE_MIN
      AND st.voltaje <= C_VOLTAGE_MAX
      AND st.consumo_wh >= 0
    ON CONFLICT (sk_red_electrica, sk_fecha, sk_tiempo) DO NOTHING;

    GET DIAGNOSTICS v_total_hechos = ROW_COUNT;

    -- =====================================================================
    -- BLOQUE 3: Marcar como procesados y finalizar auditoría
    -- =====================================================================
    UPDATE staging_telemetria
    SET procesado = TRUE,
        id_lote_procesamiento = v_lote_id
    WHERE procesado = FALSE
      AND (p_fecha_inicio IS NULL OR timestamp_lectura >= p_fecha_inicio)
      AND (p_fecha_fin    IS NULL OR timestamp_lectura <= p_fecha_fin)
      AND NOT EXISTS (
          SELECT 1 FROM err_telemetria e
          WHERE e.id_evento_origen = staging_telemetria.id_staging
            AND e.id_lote_procesamiento = v_lote_id
      );

    v_fin_ejecucion := clock_timestamp();
    UPDATE ctrl_lotes_procesamiento
    SET total_eventos      = v_total_lecturas,
        total_hechos       = v_total_hechos,
        total_huerfanos    = v_total_errores,
        total_transitorios = v_total_medidor_inactivo + v_total_consumo_negativo,
        estado             = 'COMPLETADO',
        duracion_segundos  = EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))
    WHERE id_lote = v_lote_id;

    RAISE NOTICE 'Lote % completado: % lecturas, % insertadas en fact_telemetria, % errores (% med inact, % volt fuera rango, % consumo neg) en % segundos.',
        v_lote_id, v_total_lecturas, v_total_hechos, v_total_errores,
        v_total_medidor_inactivo, v_total_voltage_out_range, v_total_consumo_negativo,
        ROUND(EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))::NUMERIC, 2);

EXCEPTION
    WHEN OTHERS THEN
        PERFORM fn_log_lote_fallido(v_lote_id, SQLERRM);
        RAISE;
END;
$$;

-- =============================================================================
-- WRAPPER: fn_reconciliar_telemetria
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_reconciliar_telemetria(
    p_fecha_inicio TIMESTAMPTZ DEFAULT NULL,
    p_fecha_fin    TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_resultado JSONB;
    v_lote_id  INTEGER;
BEGIN
    CALL sp_reconciliar_telemetria(p_fecha_inicio, p_fecha_fin);
    v_lote_id := currval('seq_lote_procesamiento');
    SELECT jsonb_build_object(
        'lote_id',            id_lote,
        'estado',             estado,
        'total_eventos',      total_eventos,
        'total_hechos',       total_hechos,
        'total_huerfanos',    total_huerfanos,
        'total_transitorios', total_transitorios,
        'duracion_segundos',  duracion_segundos,
        'fecha_ejecucion',    fecha_ejecucion
    ) INTO v_resultado
    FROM ctrl_lotes_procesamiento
    WHERE id_lote = v_lote_id;
    RETURN v_resultado;
END;
$$;

COMMENT ON PROCEDURE sp_reconciliar_telemetria IS
'SP idempotente de reconciliación ELT para telemetría. Bulk INSERT con conversión Wh→kWh,
validación de voltaje/consumo, resolución de SKs.';
COMMENT ON FUNCTION fn_reconciliar_telemetria IS
'Wrapper JSON para invocación desde n8n. Retorna resumen del lote procesado.';