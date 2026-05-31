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
-- ------------------------------------------------------------------------------
-- En un bloque EXCEPTION de PL/pgSQL, Postgres revierte al savepoint del BEGIN,
-- por lo que el INSERT del lote 'INICIADO' tambien se deshace y el posterior
-- UPDATE ... 'FALLIDO' no afecta filas; el RAISE final revierte todo y NO queda
-- rastro del fallo. Para auditar el fallo se escribe por una conexion autonoma
-- (dblink), que hace COMMIT independiente y sobrevive al ROLLBACK del SP.
-- La cadena de conexion es configurable (GUC app.dblink_conn); por defecto usa
-- la base actual (valido en instalaciones locales y, configurando credenciales,
-- en Supabase u otros Postgres gestionados).
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
    -- Si dblink no esta configurado, no enmascarar el error original del SP.
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
    -- Identificador único del lote actual
    v_lote_id          INTEGER;

    -- Contadores para la tabla de control
    v_total_eventos    INTEGER := 0;
    v_total_hechos     INTEGER := 0;
    v_total_huerfanos   INTEGER := 0;
    v_total_transitorios INTEGER := 0;

    -- Temporización
    v_inicio_ejecucion TIMESTAMPTZ;
    v_fin_ejecucion    TIMESTAMPTZ;

    -- Variables de iteración para el cursor de pares
    v_rec              RECORD;
    v_duracion         NUMERIC(10,2);
    v_sk_tiempo        BIGINT;
    v_sk_red           BIGINT;
    v_sk_geo           BIGINT;
    v_sk_clientes      BIGINT;
    v_existe_hecho     BOOLEAN;
    v_existe_error     BOOLEAN;
    v_sk_tipo_evento   BIGINT;
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
    /*
    Algoritmo:
      Para cada medidor, se ordenan los eventos cronológicamente con ROW_NUMBER.
      Si el primer evento de la secuencia es POWER_RESTORATION, es huérfano
      (no hay OUTAGE previa que lo justifique). También lo es cualquier
      RESTORATION cuyo evento inmediatamente anterior NO sea OUTAGE.

      Estos eventos se insertan en err_telemetria y se marcan como procesados
      para que no interfieran en el emparejamiento del BLOQUE 2.
    */
    -- Fix H-7: el conjunto de huerfanos se MATERIALIZA en una tabla temporal.
    -- Antes vivia en un CTE que solo era visible dentro del INSERT; el UPDATE
    -- posterior lo referenciaba fuera de alcance y la reconciliacion fallaba
    -- ("relation huerfanos does not exist") en cuanto habia datos.
    DROP TABLE IF EXISTS tmp_huerfanos;
    CREATE TEMP TABLE tmp_huerfanos AS
    WITH eventos_ord AS (
        SELECT
            id_evento,
            id_medidor,
            timestamp_evento,
            tipo_evento,
            LAG(tipo_evento) OVER w AS tipo_anterior,
            LAG(id_evento)  OVER w AS id_anterior
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
        h.id_evento,
        h.id_medidor,
        h.timestamp_evento,
        h.tipo_evento,
        h.motivo,
        v_lote_id
    FROM tmp_huerfanos h
    WHERE NOT EXISTS (
        -- Verificación de idempotencia: no insertar si ya existe en err_telemetria
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = h.id_evento
    );

    GET DIAGNOSTICS v_total_huerfanos = ROW_COUNT;

    -- Marcar los huérfanos como procesados para excluirlos del emparejamiento
    UPDATE staging_eventos se
    SET procesado = TRUE
    FROM tmp_huerfanos h
    WHERE se.id_evento = h.id_evento;


    -- =====================================================================
    -- BLOQUE 2: Emparejamiento OUTAGE → RESTORATION
    -- =====================================================================
    /*
    Algoritmo:
      Tras eliminar las restauraciones huérfanas, los eventos restantes
      deberían alternar OUTAGE → RESTORATION → OUTAGE → RESTORATION.
      Usamos ROW_NUMBER para agruparlos en pares consecutivos:
        - Par 1: evento #1 (OUTAGE) + evento #2 (RESTORATION)
        - Par 2: evento #3 (OUTAGE) + evento #4 (RESTORATION)
        - ...

      Si un par contiene solo un OUTAGE (sin RESTORATION), es un evento
      abierto y se deja sin procesar para el siguiente lote.

      Si un par contiene eventos del mismo tipo (dos OUTAGE o dos RESTORATION),
      indica corrupción de secuencia y se desvía a err_telemetria.
    */
    FOR v_rec IN
        -- Fix H-3: emparejamiento robusto OUTAGE -> RESTORATION mediante LEAD.
        -- Antes se agrupaba por posicion ((seq+1)/2), lo que se desincronizaba
        -- globalmente ante secuencias corruptas (un evento extra desplazaba todos
        -- los pares siguientes y se perdian interrupciones validas). Ahora cada
        -- OUTAGE se empareja con su evento inmediatamente posterior, de modo que una
        -- anomalia solo afecta su par local. Ejemplo O O R: la 1ra OUTAGE es duplicado
        -- y la 2da empareja con R (el metodo posicional perdia ese par valido).
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
            -- eventos consumidos por esta fila (par valido = 2; outage suelto = 1)
            CASE WHEN o.next_tipo = 'POWER_RESTORATION' THEN 2 ELSE 1 END AS eventos_en_par,
            o.id_evento        AS id_outage,
            o.timestamp_evento AS ts_outage,
            o.tipo_evento      AS tipo_evento_outage,
            CASE WHEN o.next_tipo = 'POWER_RESTORATION' THEN o.next_id END AS id_restoration,
            CASE WHEN o.next_tipo = 'POWER_RESTORATION' THEN o.next_ts END AS ts_restoration,
            -- Clasificación del OUTAGE según su evento siguiente
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

        -- ----------------------------------------------------------------
        -- Caso A: Par válido (OUTAGE + RESTORATION)
        -- ----------------------------------------------------------------
        IF v_rec.clasificacion = 'PAR_VALIDO' THEN

            -- Calcular duración en minutos con precisión decimal
            v_duracion := EXTRACT(EPOCH FROM (v_rec.ts_restoration - v_rec.ts_outage)) / 60.0;

            -- Aplicar regla IEEE 1366: filtrar interrupciones < 5 minutos
            IF v_duracion < 5.0 THEN
                v_total_transitorios := v_total_transitorios + 1;

                -- Marcar ambos eventos como procesados aunque no generen hecho
                UPDATE staging_eventos
                SET procesado = TRUE
                WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);

                CONTINUE; -- Saltar a la siguiente iteración del loop
            END IF;

            -- Verificación de idempotencia a nivel de hecho:
            -- ¿Ya existe un registro con el mismo medidor y timestamp_inicio?
            SELECT EXISTS (
                SELECT 1 FROM fact_interrupciones
                WHERE id_medidor = v_rec.id_medidor
                  AND timestamp_inicio = v_rec.ts_outage
            ) INTO v_existe_hecho;

            IF v_existe_hecho THEN
                -- Marcar como procesados para no re-evaluarlos en futuros lotes
                UPDATE staging_eventos
                SET procesado = TRUE
                WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);
                CONTINUE;
            END IF;

            -- ----------------------------------------------------------------
            -- Resolución de claves sustitutas (Surrogate Key Lookup)
            -- ----------------------------------------------------------------

            -- SK de tiempo: truncar al minuto exacto del inicio de la interrupción
            SELECT sk_tiempo INTO v_sk_tiempo
            FROM dim_tiempo
            WHERE timestamp_completo = date_trunc('minute', v_rec.ts_outage);

            -- Si no existe entrada en dim_tiempo (raro pero defensivo), usar el minuto más cercano
            IF v_sk_tiempo IS NULL THEN
                SELECT sk_tiempo INTO v_sk_tiempo
                FROM dim_tiempo
                ORDER BY ABS(EXTRACT(EPOCH FROM timestamp_completo - v_rec.ts_outage))
                LIMIT 1;
            END IF;

            -- SK de red eléctrica: versión activa al momento de la interrupción
            SELECT sk_red_electrica INTO v_sk_red
            FROM dim_red_electrica
            WHERE id_medidor_origen = v_rec.id_medidor
              AND fecha_inicio <= v_rec.ts_outage
              AND (fecha_fin IS NULL OR fecha_fin > v_rec.ts_outage)
            ORDER BY fecha_inicio DESC
            LIMIT 1;

            -- Si no hay entrada en dim_red_electrica, crear una por defecto con los datos disponibles.
            -- Fix H-4: el activo por defecto se ancla a un sector "DESCONOCIDO" (get-or-create)
            -- para que la geografia quede vinculada al medidor y no a la primera fila arbitraria.
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

            -- SK de geografía: se DERIVA del activo de red resuelto (Fix H-4).
            -- La geografia es un atributo del medidor en dim_red_electrica; esto restaura
            -- el drill-down y los filtros por sector geografico exigidos por la rubrica.
            SELECT sk_geografia_urbana INTO v_sk_geo
            FROM dim_red_electrica
            WHERE sk_red_electrica = v_sk_red;

            -- Defensa: si el activo no tuviera geografia asignada, anclar a SECTOR_DESCONOCIDO.
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

            -- SK de clientes (denominador dinámico SCD Tipo 2): inventario activo al momento de la interrupción
            SELECT sk_clientes INTO v_sk_clientes
            FROM dim_clientes_inventario
            WHERE fecha_inicio <= v_rec.ts_outage
              AND (fecha_fin IS NULL OR fecha_fin > v_rec.ts_outage)
            ORDER BY fecha_inicio DESC
            LIMIT 1;

            -- Si no hay inventario histórico, no se puede calcular SAIDI/SAIFI.
            -- Insertar una fila por defecto para evitar NULLs en la FK.
            IF v_sk_clientes IS NULL THEN
                INSERT INTO dim_clientes_inventario (
                    total_clientes_servidos, fecha_inicio, activo_bool
                ) VALUES (
                    1, -- valor mínimo; debe actualizarse con datos reales
                    '2020-01-01 00:00:00+00'::TIMESTAMPTZ,
                    TRUE
                )
                RETURNING sk_clientes INTO v_sk_clientes;
            END IF;

            -- ----------------------------------------------------------------
            -- Resolución de sk_tipo_evento (nueva columna en fact_interrupciones)
            -- ----------------------------------------------------------------
            SELECT sk_tipo_evento INTO v_sk_tipo_evento
            FROM dim_tipo_evento
            WHERE codigo_evento = v_rec.tipo_evento_outage;

            IF v_sk_tipo_evento IS NULL THEN
                -- Tipo de evento desconocido: usar -1 y registrar error
                v_sk_tipo_evento := -1;

                INSERT INTO err_telemetria (
                    id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                    tipo_error, motivo_error, id_lote_procesamiento,
                    detalle_tecnico
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

            -- ----------------------------------------------------------------
            -- Insertar hecho en la tabla de hechos
            -- ----------------------------------------------------------------
            INSERT INTO fact_interrupciones (
                sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes,
                sk_tipo_evento,
                id_medidor, timestamp_inicio, timestamp_fin,
                duracion_minutos, clientes_afectados,
                id_lote_procesamiento
            ) VALUES (
                v_sk_tiempo,
                v_sk_red,
                v_sk_geo,
                v_sk_clientes,
                v_sk_tipo_evento,
                v_rec.id_medidor,
                v_rec.ts_outage,
                v_rec.ts_restoration,
                v_duracion,
                1, -- Un medidor = un cliente afectado (configurable si hay múltiples clientes por medidor)
                v_lote_id
            );

            v_total_hechos := v_total_hechos + 1;

            -- Marcar ambos eventos del par como procesados
            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);

        -- ----------------------------------------------------------------
        -- Caso B: OUTAGE abierto (sin RESTORATION aún)
        -- Se deja sin procesar; se emparejará en el siguiente lote.
        -- ----------------------------------------------------------------
        ELSIF v_rec.clasificacion = 'OUTAGE_ABIERTO' THEN
            -- No se hace nada: el evento sigue con procesado = FALSE
            NULL;

        -- ----------------------------------------------------------------
        -- Caso C: RESTAURACIÓN solitaria (ya se manejó en BLOQUE 1, pero
        --         por defensa, si alguna escapó, se captura aquí)
        -- ----------------------------------------------------------------
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

        -- ----------------------------------------------------------------
        -- Caso D: DOBLE OUTAGE (dos caídas consecutivas sin restauración)
        -- Indica posible duplicación de eventos del medidor.
        -- ----------------------------------------------------------------
        ELSIF v_rec.clasificacion = 'DOBLE_OUTAGE' THEN
            INSERT INTO err_telemetria (
                id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                motivo_error, id_lote_procesamiento,
                detalle_tecnico
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

        -- ----------------------------------------------------------------
        -- Caso E: DOBLE RESTAURACIÓN (debería haberse capturado antes)
        -- ----------------------------------------------------------------
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
        total_huerfanos     = v_total_huerfanos,
        total_transitorios = v_total_transitorios,
        estado             = 'COMPLETADO',
        duracion_segundos  = EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))
    WHERE id_lote = v_lote_id;

    -- =====================================================================
    -- Log informativo (visible en los logs de Supabase/PostgreSQL)
    -- =====================================================================
    RAISE NOTICE 'Lote % completado: % eventos, % hechos, % huérfanos, % transitorios (<5 min) en % segundos.',
        v_lote_id, v_total_eventos, v_total_hechos, v_total_huerfanos,
        v_total_transitorios,
        ROUND(EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))::NUMERIC, 2);

EXCEPTION
    WHEN OTHERS THEN
        -- Fix H-6: registrar el lote como FALLIDO de forma AUTONOMA (sobrevive al
        -- ROLLBACK que provoca el RAISE) y relanzar para revertir el trabajo parcial.
        PERFORM fn_log_lote_fallido(v_lote_id, SQLERRM);

        RAISE;
END;
$$;


-- =============================================================================
-- WRAPPER: Función SQL para invocación programática desde n8n o cron
-- =============================================================================

/*
n8n puede invocar este procedimiento mediante el nodo "Execute SQL" de Supabase
o mediante una tarea programada con pg_cron. El wrapper devuelve un resumen
JSON para facilitar el monitoreo desde n8n y evitar tener que parsear logs.

Ejemplo de invocación desde n8n (Supabase node):
  SELECT * FROM fn_reconciliar_interrupciones(
      '2025-01-01 00:00:00+00'::TIMESTAMPTZ,
      '2025-01-31 23:59:59+00'::TIMESTAMPTZ
  );

Ejemplo con pg_cron (procesar las últimas 24 horas cada hora):
  SELECT cron.schedule(
      'reconciliacion-horaria',
      '0 * * * *',
      'CALL sp_reconciliar_interrupciones(
          NOW() - INTERVAL ''25 hours'',
          NOW() - INTERVAL ''1 hour''
      )'
  );
*/

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
    -- Obtener el próximo ID de lote antes de ejecutar
    v_lote_id := currval('seq_lote_procesamiento') + 1;

    -- Ejecutar el stored procedure
    CALL sp_reconciliar_interrupciones(p_fecha_inicio, p_fecha_fin);

    -- Leer el resultado desde la tabla de control
    SELECT jsonb_build_object(
        'lote_id',           id_lote,
        'estado',            estado,
        'total_eventos',     total_eventos,
        'total_hechos',      total_hechos,
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


COMMENT ON PROCEDURE sp_reconciliar_interrupciones IS
'SP idempotente de reconciliación ELT. Empareja POWER_OUTAGE con POWER_RESTORATION,
aplica filtro IEEE 1366 (< 5 min), desvía huérfanos a err_telemetria.';

COMMENT ON FUNCTION fn_reconciliar_interrupciones IS
'Wrapper JSON para invocación desde n8n. Retorna resumen del lote procesado.';


-- =============================================================================
-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)
-- MATERIA:  Gestión de Datos — Prof. Armen Djenanian
-- SP3:      sp_reconciliar_telemetria() + fn_reconciliar_telemetria()
-- PLATAFORMA: Supabase (PostgreSQL 15+)
--
-- NOTAS DE ARQUITECTURA (embebidas como comentarios):
--
--   Estrategia ELT para Telemetría:
--     A diferencia de sp_reconciliar_interrupciones (cursor + window functions),
--     este SP usa un INSERT masivo basado en conjuntos (set-based) que es más
--     eficiente para grandes volúmenes de lecturas horarias.
--
--   Algoritmo:
--     Bloque 0: Inicialización de lote (mismo patrón que interrupciones)
--     Bloque 1: Validación y desvío de errores (MEDIDOR_INACTIVO, VOLTAGE_OUT_OF_RANGE, CONSUMO_NEGATIVO)
--     Bloque 2: Bulk INSERT con conversión Wh→kWh y resolución de SKs
--     Bloque 3: Marcar staging.procesado=TRUE, actualizar ctrl_lotes_procesamiento
--
--   Idempotencia:
--     - Solo procesa registros con procesado = FALSE
--     - ON CONFLICT DO NOTHING previene duplicados en fact_telemetria
--     - Marcar procesado = TRUE al final (misma transacción, ROLLBACK si falla)
--     - Ejecutar múltiples veces produce el mismo resultado que una vez
--
--   Validación en Bloque 1:
--     Los errores se desvían a err_telemetria con tipo_error específico para
--     facilitar el monitoreo y debugging desde n8n.
-- =============================================================================


CREATE OR REPLACE PROCEDURE sp_reconciliar_telemetria(
    p_fecha_inicio TIMESTAMPTZ DEFAULT NULL,
    p_fecha_fin    TIMESTAMPTZ DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Identificador único del lote actual
    v_lote_id          INTEGER;

    -- Contadores para la tabla de control
    v_total_lecturas   INTEGER := 0;
    v_total_hechos     INTEGER := 0;
    v_total_errores    INTEGER := 0;
    v_total_medidor_inactivo INTEGER := 0;
    v_total_voltage_out_range INTEGER := 0;
    v_total_consumo_negativo  INTEGER := 0;

    -- Temporización
    v_inicio_ejecucion TIMESTAMPTZ;
    v_fin_ejecucion    TIMESTAMPTZ;

    -- Constantes de validación
    C_VOLTAGE_MIN      NUMERIC(8,2) := 0;
    C_VOLTAGE_MAX      NUMERIC(8,2) := 1000;
    C_VOLTAGE_NORMAL_MIN NUMERIC(8,2) := 180;
    C_VOLTAGE_NORMAL_MAX NUMERIC(8,2) := 260;
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
    /*
    Validaciones realizadas:
      - Voltaje fuera de rango (0-1000V aceptable, 180-260V normal)
      - Consumo negativo
      - Medidor inactivo (no existe en dim_red_electrica o activo_bool=FALSE)

    Cada tipo de error se registra en err_telemetria con tipo_error específico.
    */

    -- Contar lecturas totales que serán procesadas
    SELECT COUNT(*) INTO v_total_lecturas
    FROM staging_telemetria st
    WHERE st.procesado = FALSE
      AND (p_fecha_inicio IS NULL OR st.timestamp_lectura >= p_fecha_inicio)
      AND (p_fecha_fin    IS NULL OR st.timestamp_lectura <= p_fecha_fin);

    -- ----------------------------------------------------------------
    -- Desvío: Medidores inactivos
    -- Un medidor es inactivo si NO existe en dim_red_electrica con
    -- fecha_inicio <= timestamp_lectura Y (fecha_fin IS NULL OR fecha_fin > timestamp_lectura)
    -- ----------------------------------------------------------------
    -- Fix H-7 (telemetria): materializar el conjunto en tabla temporal. El CTE
    -- medidores_inactivos solo existia dentro del INSERT y el UPDATE posterior lo
    -- referenciaba fuera de alcance -> "relation medidores_inactivos does not exist".
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
        mi.id_staging,
        mi.id_medidor,
        mi.timestamp_lectura,
        mi.tipo_lectura,
        'MEDIDOR_INACTIVO',
        mi.motivo,
        jsonb_build_object(
            'consumo_wh', mi.consumo_wh,
            'voltaje', mi.voltaje,
            'tipo_lectura', mi.tipo_lectura,
            'bloque', 'BLOQUE_1'
        )::TEXT,
        v_lote_id
    FROM tmp_medidores_inactivos mi
    WHERE NOT EXISTS (
        -- Idempotencia: no insertar si ya existe en err_telemetria
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = mi.id_staging
          AND e.tipo_error = 'MEDIDOR_INACTIVO'
    );

    GET DIAGNOSTICS v_total_medidor_inactivo = ROW_COUNT;
    v_total_errores := v_total_errores + v_total_medidor_inactivo;

    -- Marcar medidores inactivos como procesados para excluirlos del INSERT
    UPDATE staging_telemetria st
    SET procesado = TRUE
    FROM tmp_medidores_inactivos mi
    WHERE st.id_staging = mi.id_staging;

    -- ----------------------------------------------------------------
    -- Desvío: Voltaje fuera de rango (0-1000V aceptable)
    -- Los voltajes fuera de rango normal (180-260V) se registran pero
    -- NO se excluyen del INSERT - se marcan en err_telemetria como警告
    -- ----------------------------------------------------------------
    WITH voltajes_invalidos AS (
        SELECT DISTINCT
            st.id_staging,
            st.id_medidor,
            st.timestamp_lectura,
            st.consumo_wh,
            st.voltaje,
            st.tipo_lectura,
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
              -- Solo si el medidor está activo (ya se validó arriba)
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
        vi.id_staging,
        vi.id_medidor,
        vi.timestamp_lectura,
        vi.tipo_lectura,
        'VOLTAGE_OUT_OF_RANGE',
        vi.motivo,
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

    -- NOTE: Voltajes fuera de rango NO se marcan como procesados -
    -- se incluyen en el INSERT pero se registran como advertencia

    -- ----------------------------------------------------------------
    -- Desvío: Consumo negativo
    -- ----------------------------------------------------------------
    -- Fix H-7 (telemetria): materializar consumo_negativo en tabla temporal.
    DROP TABLE IF EXISTS tmp_consumo_negativo;
    CREATE TEMP TABLE tmp_consumo_negativo AS
        SELECT DISTINCT
            st.id_staging,
            st.id_medidor,
            st.timestamp_lectura,
            st.consumo_wh,
            st.voltaje,
            st.tipo_lectura,
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
        cn.id_staging,
        cn.id_medidor,
        cn.timestamp_lectura,
        cn.tipo_lectura,
        'CONSUMO_NEGATIVO',
        cn.motivo,
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

    -- Marcar consumos negativos como procesados
    UPDATE staging_telemetria st
    SET procesado = TRUE
    FROM tmp_consumo_negativo cn
    WHERE st.id_staging = cn.id_staging;

    -- =====================================================================
    -- BLOQUE 2: Bulk INSERT con conversión de unidades y resolución de SKs
    -- =====================================================================
    /*
    Conversiones y resolvedores:
      - consumo_wh → consumo_kwh (÷ 1000)
      - sk_tiempo: DATE_TRUNC('hour', timestamp_lectura) → dim_tiempo.sk_tiempo
      - sk_red_electrica: lookup por id_medidor + fecha_inicio <= timestamp
      - sk_geografia_urbana: JOIN dim_red_electrica → dim_geografia_urbana
      - sk_tipo_evento: lookup por tipo_lectura → dim_tipo_evento.codigo_evento

    ON CONFLICT DO NOTHING: si ya existe (medidor + hora), se ignora
    */

    INSERT INTO fact_telemetria (
        sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_tipo_evento,
        timestamp_lectura, consumo_kwh, voltaje, id_lote_procesamiento
    )
    SELECT
        dt.sk_tiempo,
        dre.sk_red_electrica,
        -- Fix H-4: geografia derivada del activo de red (no la primera fila disponible)
        COALESCE(dre.sk_geografia_urbana, -1),
        COALESCE(dte.sk_tipo_evento, -1),            -- Unknown si no existe el tipo
        DATE_TRUNC('hour', st.timestamp_lectura),
        st.consumo_wh / 1000.0,                      -- Conversión Wh → kWh
        st.voltaje,
        v_lote_id
    FROM staging_telemetria st
    -- Resolver SK de tiempo: truncar timestamp_lectura a hora
    JOIN dim_tiempo dt
        ON dt.timestamp_completo = DATE_TRUNC('hour', st.timestamp_lectura)
    -- Resolver SK de red eléctrica: medidor activo al momento de la lectura
    JOIN dim_red_electrica dre
        ON dre.id_medidor_origen = st.id_medidor
        AND dre.fecha_inicio <= st.timestamp_lectura
        AND (dre.fecha_fin IS NULL OR dre.fecha_fin > st.timestamp_lectura)
        AND dre.activo_bool = TRUE
    -- Resolver SK de tipo de evento: por codigo_evento = tipo_lectura
    LEFT JOIN dim_tipo_evento dte
        ON dte.codigo_evento = st.tipo_lectura
    WHERE st.procesado = FALSE
      AND (p_fecha_inicio IS NULL OR st.timestamp_lectura >= p_fecha_inicio)
      AND (p_fecha_fin    IS NULL OR st.timestamp_lectura <= p_fecha_fin)
      -- Validaciones: solo incluir registros válidos
      AND st.voltaje >= C_VOLTAGE_MIN
      AND st.voltaje <= C_VOLTAGE_MAX
      AND st.consumo_wh >= 0
    ON CONFLICT (sk_red_electrica, DATE_TRUNC('hour', timestamp_lectura, 'UTC')) DO NOTHING;

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
      -- Excluir los que ya se marcaron en BLOQUE 1 (medidor inactivo, consumo negativo)
      AND NOT EXISTS (
          SELECT 1 FROM err_telemetria e
          WHERE e.id_evento_origen = staging_telemetria.id_staging
            AND e.id_lote_procesamiento = v_lote_id
      );

    -- =====================================================================
    -- Finalización: actualizar ctrl_lotes_procesamiento
    -- =====================================================================
    v_fin_ejecucion := clock_timestamp();

    UPDATE ctrl_lotes_procesamiento
    SET total_eventos      = v_total_lecturas,
        total_hechos       = v_total_hechos,
        total_huerfanos    = v_total_errores,
        total_transitorios = v_total_medidor_inactivo + v_total_consumo_negativo,
        estado             = 'COMPLETADO',
        duracion_segundos  = EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))
    WHERE id_lote = v_lote_id;

    -- =====================================================================
    -- Log informativo
    -- =====================================================================
    RAISE NOTICE 'Lote % completado: % lecturas, % insertadas en fact_telemetria, % errores (% med inact, % volt fuera rango, % consumo neg) en % segundos.',
        v_lote_id, v_total_lecturas, v_total_hechos, v_total_errores,
        v_total_medidor_inactivo, v_total_voltage_out_range, v_total_consumo_negativo,
        ROUND(EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))::NUMERIC, 2);

EXCEPTION
    WHEN OTHERS THEN
        -- Fix H-6: registro autonomo del lote FALLIDO (ver fn_log_lote_fallido).
        PERFORM fn_log_lote_fallido(v_lote_id, SQLERRM);

        RAISE;
END;
$$;


-- =============================================================================
-- WRAPPER: Función SQL para invocación programática desde n8n o cron
-- =============================================================================

/*
Wrapper JSON para sp_reconciliar_telemetria(). Devuelve resumen del lote
procesado para facilitar monitoreo desde n8n.

Ejemplo de invocación desde n8n (Supabase node):
  SELECT * FROM fn_reconciliar_telemetria(
      '2025-01-01 00:00:00+00'::TIMESTAMPTZ,
      '2025-01-31 23:59:59+00'::TIMESTAMPTZ
  );

Ejemplo con pg_cron (procesar las últimas 24 horas cada hora):
  SELECT cron.schedule(
      'reconciliacion-telemetria-horaria',
      '5 * * * *',
      'CALL sp_reconciliar_telemetria(
          NOW() - INTERVAL ''25 hours'',
          NOW() - INTERVAL ''1 hour''
      )'
  );
*/

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
    -- Obtener el próximo ID de lote antes de ejecutar
    v_lote_id := currval('seq_lote_procesamiento') + 1;

    -- Ejecutar el stored procedure
    CALL sp_reconciliar_telemetria(p_fecha_inicio, p_fecha_fin);

    -- Leer el resultado desde la tabla de control
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


COMMENT ON PROCEDURE sp_reconciliar_telemetria IS
'SP idempotente de reconciliación ELT para telemetría. Bulk INSERT con conversión Wh→kWh,
validación de voltaje/consumo, resolución de SKs.';

COMMENT ON FUNCTION fn_reconciliar_telemetria IS
'Wrapper JSON para invocación desde n8n. Retorna resumen del lote procesado.';