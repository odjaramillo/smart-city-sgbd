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
    ),
    huerfanos AS (
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
          AND (tipo_anterior IS NULL OR tipo_anterior = 'POWER_RESTORATION')
    )
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
    FROM huerfanos h
    WHERE NOT EXISTS (
        -- Verificación de idempotencia: no insertar si ya existe en err_telemetria
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = h.id_evento
    );

    GET DIAGNOSTICS v_total_huerfanos = ROW_COUNT;

    -- Marcar los huérfanos como procesados para excluirlos del emparejamiento
    UPDATE staging_eventos se
    SET procesado = TRUE
    FROM huerfanos h
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
        WITH eventos_limpios AS (
            SELECT
                id_evento,
                id_medidor,
                timestamp_evento,
                tipo_evento,
                ROW_NUMBER() OVER (
                    PARTITION BY id_medidor
                    ORDER BY timestamp_evento, id_evento
                ) AS seq
            FROM staging_eventos
            WHERE procesado = FALSE
              AND (p_fecha_inicio IS NULL OR timestamp_evento >= p_fecha_inicio)
              AND (p_fecha_fin    IS NULL OR timestamp_evento <= p_fecha_fin)
        ),
        pares AS (
            SELECT
                id_medidor,
                (seq + 1) / 2                    AS num_par,
                COUNT(*)                         AS eventos_en_par,
                MAX(CASE WHEN tipo_evento = 'POWER_OUTAGE'
                    THEN id_evento END)          AS id_outage,
                MAX(CASE WHEN tipo_evento = 'POWER_OUTAGE'
                    THEN timestamp_evento END)   AS ts_outage,
                MAX(CASE WHEN tipo_evento = 'POWER_RESTORATION'
                    THEN id_evento END)          AS id_restoration,
                MAX(CASE WHEN tipo_evento = 'POWER_RESTORATION'
                    THEN timestamp_evento END)   AS ts_restoration
            FROM eventos_limpios
            GROUP BY id_medidor, (seq + 1) / 2
        )
        SELECT
            p.id_medidor,
            p.num_par,
            p.eventos_en_par,
            p.id_outage,
            p.ts_outage,
            p.id_restoration,
            p.ts_restoration,
            -- Clasificación del par
            CASE
                WHEN p.eventos_en_par = 2
                 AND p.id_outage IS NOT NULL
                 AND p.id_restoration IS NOT NULL
                    THEN 'PAR_VALIDO'
                WHEN p.eventos_en_par = 1
                 AND p.id_outage IS NOT NULL
                    THEN 'OUTAGE_ABIERTO'
                WHEN p.eventos_en_par = 1
                 AND p.id_restoration IS NOT NULL
                    THEN 'RESTAURACION_SOLITARIA'
                WHEN p.eventos_en_par = 2
                 AND p.id_outage IS NULL
                    THEN 'DOBLE_RESTAURACION'
                WHEN p.eventos_en_par = 2
                 AND p.id_restoration IS NULL
                    THEN 'DOBLE_OUTAGE'
                ELSE 'ERROR_DESCONOCIDO'
            END AS clasificacion
        FROM pares p
        ORDER BY p.id_medidor, p.num_par
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

            -- Si no hay entrada en dim_red_electrica, crear una por defecto con los datos disponibles
            IF v_sk_red IS NULL THEN
                INSERT INTO dim_red_electrica (
                    id_medidor, id_medidor_origen, codigo_medidor,
                    transformador, circuito, subestacion,
                    fecha_inicio, activo_bool
                ) VALUES (
                    v_rec.id_medidor,
                    v_rec.id_medidor,
                    'MED-' || v_rec.id_medidor::TEXT,
                    'TRANSFORMADOR_DESCONOCIDO',
                    'CIRCUITO_DESCONOCIDO',
                    'SUBESTACION_DESCONOCIDA',
                    v_rec.ts_outage - INTERVAL '1 day',
                    TRUE
                )
                RETURNING sk_red_electrica INTO v_sk_red;
            END IF;

            -- SK de geografía: se obtiene desde dim_red_electrica vía JOIN
            -- (En una implementación real, la geografía se vincula al medidor en su dimensión)
            -- Para este proyecto académico, buscamos una entrada geográfica por defecto
            SELECT sk_geografia_urbana INTO v_sk_geo
            FROM dim_geografia_urbana
            ORDER BY sk_geografia_urbana
            LIMIT 1;

            IF v_sk_geo IS NULL THEN
                INSERT INTO dim_geografia_urbana (sector_urbano, distrito)
                VALUES ('SECTOR_DESCONOCIDO', 'DISTRITO_DESCONOCIDO')
                RETURNING sk_geografia_urbana INTO v_sk_geo;
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
            -- Insertar hecho en la tabla de hechos
            -- ----------------------------------------------------------------
            INSERT INTO fact_interrupciones (
                sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes,
                id_medidor, timestamp_inicio, timestamp_fin,
                duracion_minutos, clientes_afectados,
                id_lote_procesamiento
            ) VALUES (
                v_sk_tiempo,
                v_sk_red,
                v_sk_geo,
                v_sk_clientes,
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
        -- En caso de error, marcar el lote como fallido y relanzar la excepción
        -- para que la transacción haga ROLLBACK completo.
        UPDATE ctrl_lotes_procesamiento
        SET estado = 'FALLIDO'
        WHERE id_lote = v_lote_id;

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
