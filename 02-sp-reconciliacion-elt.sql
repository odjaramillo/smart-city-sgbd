-- ==============================================================================
-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)
-- MATERIA:  Gestión de Datos — Prof. Armen Djenanian
-- FASE 2:   Pipeline de Ingesta Idempotente (Estrategia ELT)
-- PLATAFORMA: Supabase (PostgreSQL 15+)
--
-- NOTAS DE ARQUITECTURA (embebidas como comentarios):
--
--   Estrategia ELT (no ETL):
--     La transformación ocurre DENTRO de la base de datos, no en n8n. PostgreSQL
--     es un motor de conjuntos extremadamente eficiente; mover datos a n8n para
--     transformarlos y luego devolverlos sería un antipatrón de latencia y costo
--     de red. El patrón es:
--       n8n → INSERT en staging_eventos (EL)
--       PostgreSQL → sp_reconciliar_interrupciones (T)
--       Power BI → SELECT sobre vistas analíticas (L)
--
--   Concurrencia (FOR UPDATE SKIP LOCKED):
--     El SP bloquea las filas de staging_eventos con FOR UPDATE SKIP LOCKED al
--     inicio de la transacción. Si dos instancias del SP se ejecutan en paralelo,
--     cada una procesa un subconjunto disjunto de filas. Nunca se procesa la
--     misma fila dos veces. Esto es crítico para despliegues con múltiples
--     workers o invocaciones cron superpuestas.
--
--   RETURNING en cada INSERT:
--     Todo INSERT utiliza la cláusula RETURNING para obtener la clave sustituta
--     generada. No se usa currval() sin nextval() previo en la misma sesión.
--     Esto elimina la fragilidad de sesión y garantiza que cada SK obtenida
--     corresponde exactamente a la fila recién insertada.
--
--   Escaneo sin filtro de fecha (cross-batch pairing):
--     El SP procesa TODAS las filas de staging_eventos con procesado = FALSE,
--     sin filtro de fecha. Esto permite emparejar eventos OUTAGE de un lote
--     anterior con eventos RESTORATION del lote actual. Un OUTAGE sin par
--     permanece en staging (procesado = FALSE) hasta que llegue su restauración.
--
--   Fail-fast en dimensiones (RAISE EXCEPTION):
--     Si una dimensión requerida no tiene entrada para el evento, el SP lanza
--     RAISE EXCEPTION y aborta la transacción. No crea dimensiones "DESCONOCIDO"
--     como fallback silencioso. Esto fuerza a que las dimensiones se carguen
--     correctamente antes de ejecutar el ELT. Los eventos huérfanos (sin error
--     de dimensión) se desvían a err_telemetria, que es cuarentena, no fallback.
--
--   Idempotencia:
--     - Solo procesa eventos con procesado = FALSE.
--     - Verifica NOT EXISTS antes de insertar en err_telemetria.
--     - La constraint UNIQUE(id_medidor, timestamp_inicio) en fact_interrupciones
--       previene duplicados a nivel de esquema.
--     - Ejecutar el SP N veces produce el mismo resultado que ejecutarlo 1 vez.
--
--   Regla IEEE 1366 — Interrupciones menores a 5 minutos:
--     Eventos con duración < 5 minutos son "momentary interruptions" y NO deben
--     contabilizarse para SAIDI/SAIFI rutinario. El SP aplica este filtro
--     después de calcular la duración del par OUTAGE→RESTORATION.
-- ==============================================================================

DROP PROCEDURE IF EXISTS sp_reconciliar_interrupciones CASCADE;
DROP FUNCTION  IF EXISTS fn_reconciliar_interrupciones CASCADE;

CREATE OR REPLACE PROCEDURE sp_reconciliar_interrupciones(
    INOUT p_lote_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_eventos      INTEGER := 0;
    v_total_hechos       INTEGER := 0;
    v_total_huerfanos    INTEGER := 0;
    v_total_transitorios INTEGER := 0;
    v_inicio_ejecucion   TIMESTAMPTZ;
    v_fin_ejecucion      TIMESTAMPTZ;
    v_rec                RECORD;
    v_duracion           NUMERIC(10,2);
    v_sk_tiempo          BIGINT;
    v_sk_red             BIGINT;
    v_sk_geo             BIGINT;
    v_sk_clientes        BIGINT;
    v_fecha_outage       DATE;
    v_existe_error       BOOLEAN;
BEGIN
    -- =====================================================================
    -- BLOQUE 0: Inicialización del lote
    -- RETURNING para obtener el id_lote generado por la secuencia.
    -- =====================================================================
    v_inicio_ejecucion := clock_timestamp();

    INSERT INTO ctrl_lotes_procesamiento (
        fecha_inicio, fecha_fin, estado
    ) VALUES (
        '-infinity'::TIMESTAMPTZ,
        'infinity'::TIMESTAMPTZ,
        'INICIADO'
    )
    RETURNING id_lote INTO p_lote_id;

    -- =====================================================================
    -- BLOQUE 1: Bloqueo concurrente de staging (FOR UPDATE SKIP LOCKED)
    --
    -- Se copian las filas no procesadas a una tabla temporal, bloqueándolas
    -- en staging_eventos. Si otra instancia del SP corre en paralelo, verá
    -- estas filas como locked y las saltará (SKIP LOCKED). La tabla temporal
    -- se elimina automáticamente al finalizar la transacción (ON COMMIT DROP).
    -- =====================================================================
    DROP TABLE IF EXISTS _locked_events;

    CREATE TEMP TABLE _locked_events ON COMMIT DROP AS
    SELECT
        id_evento,
        id_medidor,
        timestamp_evento,
        tipo_evento
    FROM staging_eventos
    WHERE procesado = FALSE
    ORDER BY id_medidor, timestamp_evento, id_evento
    FOR UPDATE SKIP LOCKED;

    -- Si no hay eventos para procesar, cerrar el lote y salir
    IF NOT EXISTS (SELECT 1 FROM _locked_events) THEN
        UPDATE ctrl_lotes_procesamiento
        SET estado            = 'COMPLETADO',
            duracion_segundos = EXTRACT(EPOCH FROM (clock_timestamp() - v_inicio_ejecucion))
        WHERE id_lote = p_lote_id;

        RAISE NOTICE 'Lote %: sin eventos pendientes.', p_lote_id;
        RETURN;
    END IF;

    -- =====================================================================
    -- BLOQUE 2: Detección y desvío de RESTAURACIONES HUÉRFANAS
    --
    -- Algoritmo: para cada medidor, se ordenan los eventos cronológicamente.
    -- Si el primer evento es POWER_RESTORATION, es huérfano (no hay OUTAGE
    -- previa). También lo es cualquier RESTORATION cuyo evento inmediatamente
    -- anterior NO sea OUTAGE.
    -- =====================================================================
    WITH eventos_ord AS (
        SELECT
            id_evento,
            id_medidor,
            timestamp_evento,
            tipo_evento,
            LAG(tipo_evento) OVER w AS tipo_anterior
        FROM _locked_events
        WINDOW w AS (PARTITION BY id_medidor ORDER BY timestamp_evento, id_evento)
    ),
    huerfanos AS (
        SELECT
            id_evento,
            id_medidor,
            timestamp_evento,
            tipo_evento,
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
        p_lote_id
    FROM huerfanos h
    WHERE NOT EXISTS (
        SELECT 1 FROM err_telemetria e
        WHERE e.id_evento_origen = h.id_evento
    );

    GET DIAGNOSTICS v_total_huerfanos = ROW_COUNT;

    -- Marcar huérfanos como procesados en staging
    UPDATE staging_eventos se
    SET procesado = TRUE
    FROM _locked_events le
    WHERE se.id_evento = le.id_evento
      AND le.id_evento IN (
          SELECT h.id_evento
          FROM (
              SELECT
                  id_evento,
                  tipo_evento,
                  LAG(tipo_evento) OVER (PARTITION BY id_medidor ORDER BY timestamp_evento, id_evento) AS tipo_anterior
              FROM _locked_events
          ) h
          WHERE h.tipo_evento = 'POWER_RESTORATION'
            AND (h.tipo_anterior IS NULL OR h.tipo_anterior = 'POWER_RESTORATION')
      );

    -- Eliminar huérfanos de la tabla temporal para el emparejamiento
    DELETE FROM _locked_events
    WHERE id_evento IN (
        SELECT h.id_evento
        FROM (
            SELECT
                id_evento,
                tipo_evento,
                LAG(tipo_evento) OVER (PARTITION BY id_medidor ORDER BY timestamp_evento, id_evento) AS tipo_anterior
            FROM _locked_events
        ) h
        WHERE h.tipo_evento = 'POWER_RESTORATION'
          AND (h.tipo_anterior IS NULL OR h.tipo_anterior = 'POWER_RESTORATION')
    );

    -- =====================================================================
    -- BLOQUE 3: Emparejamiento OUTAGE → RESTORATION
    --
    -- Tras eliminar huérfanos, los eventos restantes deberían alternar
    -- OUTAGE → RESTORATION. Se agrupan en pares consecutivos con ROW_NUMBER.
    -- Sin filtro de fecha: permite emparejar eventos de lotes anteriores
    -- (cross-batch pairing).
    -- =====================================================================
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
            FROM _locked_events
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

            v_duracion := EXTRACT(EPOCH FROM (v_rec.ts_restoration - v_rec.ts_outage)) / 60.0;

            -- Regla IEEE 1366: filtrar interrupciones < 5 minutos
            IF v_duracion < 5.0 THEN
                v_total_transitorios := v_total_transitorios + 1;

                UPDATE staging_eventos
                SET procesado = TRUE
                WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);

                CONTINUE;
            END IF;

            -- Idempotencia: verificar que no exista el hecho
            IF EXISTS (
                SELECT 1 FROM fact_interrupciones
                WHERE id_medidor = v_rec.id_medidor
                  AND timestamp_inicio = v_rec.ts_outage
            ) THEN
                UPDATE staging_eventos
                SET procesado = TRUE
                WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);
                CONTINUE;
            END IF;

            -- =============================================================
            -- Resolución de claves sustitutas (FAIL-FAST)
            --
            -- Cada dimensión se busca por su clave natural. Si no existe,
            -- se lanza RAISE EXCEPTION. No se crean filas "DESCONOCIDO".
            -- =============================================================

            -- SK de tiempo: dim_tiempo a nivel de día
            v_fecha_outage := v_rec.ts_outage::DATE;

            SELECT sk_tiempo INTO v_sk_tiempo
            FROM dim_tiempo
            WHERE timestamp_completo = v_fecha_outage;

            IF v_sk_tiempo IS NULL THEN
                RAISE EXCEPTION 'DIMENSION_FALTANTE: dim_tiempo no tiene entrada para fecha %', v_fecha_outage
                    USING HINT = 'Ejecutar la carga de dim_tiempo (generate_series) antes del ELT.';
            END IF;

            -- SK de red eléctrica: SCD2 vigente al momento del outage
            SELECT sk_red_electrica INTO v_sk_red
            FROM dim_red_electrica
            WHERE id_medidor_origen = v_rec.id_medidor
              AND fecha_inicio <= v_rec.ts_outage
              AND (fecha_fin IS NULL OR fecha_fin > v_rec.ts_outage)
            ORDER BY fecha_inicio DESC
            LIMIT 1;

            IF v_sk_red IS NULL THEN
                RAISE EXCEPTION 'DIMENSION_FALTANTE: dim_red_electrica no tiene entrada SCD2 activa para medidor % en timestamp %',
                    v_rec.id_medidor, v_rec.ts_outage
                    USING HINT = 'Cargar la topología de red antes de procesar eventos del medidor.';
            END IF;

            -- SK de geografía urbana: primera entrada disponible
            -- (En producción, el vínculo medidor→geografía vendría de dim_red_electrica
            --  o de staging_eventos. Para este proyecto académico, se usa la primera fila.)
            SELECT sk_geografia_urbana INTO v_sk_geo
            FROM dim_geografia_urbana
            LIMIT 1;

            IF v_sk_geo IS NULL THEN
                RAISE EXCEPTION 'DIMENSION_FALTANTE: dim_geografia_urbana está vacía'
                    USING HINT = 'Cargar datos semilla de geografía antes del ELT.';
            END IF;

            -- SK de clientes: SCD2 vigente al momento del outage
            SELECT sk_clientes INTO v_sk_clientes
            FROM dim_clientes_inventario
            WHERE fecha_inicio <= v_rec.ts_outage
              AND (fecha_fin IS NULL OR fecha_fin > v_rec.ts_outage)
            ORDER BY fecha_inicio DESC
            LIMIT 1;

            IF v_sk_clientes IS NULL THEN
                RAISE EXCEPTION 'DIMENSION_FALTANTE: dim_clientes_inventario no tiene snapshot activo para timestamp %',
                    v_rec.ts_outage
                    USING HINT = 'Cargar inventario de clientes antes del ELT.';
            END IF;

            -- =============================================================
            -- Insertar hecho con RETURNING (obtención explícita de SK)
            -- =============================================================
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
                1,
                p_lote_id
            );

            v_total_hechos := v_total_hechos + 1;

            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento IN (v_rec.id_outage, v_rec.id_restoration);

        -- ----------------------------------------------------------------
        -- Caso B: OUTAGE abierto (sin RESTORATION aún)
        -- Se deja sin procesar para emparejar en un lote futuro.
        -- ----------------------------------------------------------------
        ELSIF v_rec.clasificacion = 'OUTAGE_ABIERTO' THEN
            NULL;

        -- ----------------------------------------------------------------
        -- Caso C: RESTAURACIÓN solitaria (defensa, debería haberse
        --         capturado en BLOQUE 2)
        -- ----------------------------------------------------------------
        ELSIF v_rec.clasificacion = 'RESTAURACION_SOLITARIA' THEN
            SELECT EXISTS (
                SELECT 1 FROM err_telemetria
                WHERE id_evento_origen = v_rec.id_restoration
            ) INTO v_existe_error;

            IF NOT v_existe_error THEN
                INSERT INTO err_telemetria (
                    id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                    motivo_error, id_lote_procesamiento
                ) VALUES (
                    v_rec.id_restoration,
                    v_rec.id_medidor,
                    v_rec.ts_restoration,
                    'POWER_RESTORATION',
                    'RESTAURACION_SOLITARIA: evento escapado del filtro de huérfanos',
                    p_lote_id
                );
            END IF;

            v_total_huerfanos := v_total_huerfanos + 1;

            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento = v_rec.id_restoration;

        -- ----------------------------------------------------------------
        -- Caso D: DOBLE OUTAGE (dos caídas consecutivas sin restauración)
        -- ----------------------------------------------------------------
        ELSIF v_rec.clasificacion = 'DOBLE_OUTAGE' THEN
            SELECT EXISTS (
                SELECT 1 FROM err_telemetria
                WHERE id_evento_origen = v_rec.id_outage
            ) INTO v_existe_error;

            IF NOT v_existe_error THEN
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
                    p_lote_id,
                    'Posible error de firmware en el medidor o duplicación en la ingesta n8n.'
                );
            END IF;

            v_total_huerfanos := v_total_huerfanos + 1;

            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento = v_rec.id_outage;

        -- ----------------------------------------------------------------
        -- Caso E: DOBLE RESTAURACIÓN
        -- ----------------------------------------------------------------
        ELSIF v_rec.clasificacion = 'DOBLE_RESTAURACION' THEN
            SELECT EXISTS (
                SELECT 1 FROM err_telemetria
                WHERE id_evento_origen = v_rec.id_restoration
            ) INTO v_existe_error;

            IF NOT v_existe_error THEN
                INSERT INTO err_telemetria (
                    id_evento_origen, id_medidor, timestamp_evento, tipo_evento,
                    motivo_error, id_lote_procesamiento
                ) VALUES (
                    v_rec.id_restoration,
                    v_rec.id_medidor,
                    v_rec.ts_restoration,
                    'POWER_RESTORATION',
                    'RESTAURACION_DUPLICADA: dos eventos POWER_RESTORATION consecutivos',
                    p_lote_id
                );
            END IF;

            v_total_huerfanos := v_total_huerfanos + 1;

            UPDATE staging_eventos
            SET procesado = TRUE
            WHERE id_evento = v_rec.id_restoration;

        END IF;

    END LOOP;

    -- =====================================================================
    -- BLOQUE 4: Finalización y registro de auditoría
    -- =====================================================================
    v_fin_ejecucion := clock_timestamp();

    UPDATE ctrl_lotes_procesamiento
    SET total_eventos      = v_total_eventos,
        total_hechos       = v_total_hechos,
        total_huerfanos    = v_total_huerfanos,
        total_transitorios = v_total_transitorios,
        estado             = 'COMPLETADO',
        duracion_segundos  = EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))
    WHERE id_lote = p_lote_id;

    RAISE NOTICE 'Lote % completado: % eventos, % hechos, % huérfanos, % transitorios (<5 min) en % segundos.',
        p_lote_id, v_total_eventos, v_total_hechos, v_total_huerfanos,
        v_total_transitorios,
        ROUND(EXTRACT(EPOCH FROM (v_fin_ejecucion - v_inicio_ejecucion))::NUMERIC, 2);

EXCEPTION
    WHEN OTHERS THEN
        UPDATE ctrl_lotes_procesamiento
        SET estado = 'FALLIDO'
        WHERE id_lote = p_lote_id;

        RAISE;
END;
$$;


-- =============================================================================
-- WRAPPER: Función SQL para invocación programática desde n8n o cron
-- =============================================================================

/*
n8n puede invocar este procedimiento mediante el nodo "Execute SQL" de Supabase
o mediante una tarea programada con pg_cron. El wrapper devuelve un resumen
JSON para facilitar el monitoreo desde n8n.

Ejemplo de invocación desde n8n:
  SELECT * FROM fn_reconciliar_interrupciones();

Ejemplo con pg_cron (procesar cada hora):
  SELECT cron.schedule(
      'reconciliacion-horaria',
      '0 * * * *',
      'SELECT fn_reconciliar_interrupciones()'
  );
*/

CREATE OR REPLACE FUNCTION fn_reconciliar_interrupciones()
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_resultado JSONB;
    v_lote_id  INTEGER;
BEGIN
    CALL sp_reconciliar_interrupciones(v_lote_id);

    SELECT jsonb_build_object(
        'lote_id',           id_lote,
        'estado',            estado,
        'total_eventos',     total_eventos,
        'total_hechos',      total_hechos,
        'total_huerfanos',   total_huerfanos,
        'total_transitorios', total_transitorios,
        'duracion_segundos', duracion_segundos,
        'fecha_ejecucion',   fecha_ejecucion
    ) INTO v_resultado
    FROM ctrl_lotes_procesamiento
    WHERE id_lote = v_lote_id;

    RETURN v_resultado;
END;
$$;


COMMENT ON PROCEDURE sp_reconciliar_interrupciones IS
'SP idempotente de reconciliación ELT con FOR UPDATE SKIP LOCKED. Empareja POWER_OUTAGE con POWER_RESTORATION,
aplica filtro IEEE 1366 (< 5 min), desvía huérfanos a err_telemetria, fail-fast en dimensiones faltantes.';

COMMENT ON FUNCTION fn_reconciliar_interrupciones IS
'Wrapper JSON para invocación desde n8n. Retorna resumen del lote procesado. Sin parámetros de fecha (escanea todo staging no procesado).';
