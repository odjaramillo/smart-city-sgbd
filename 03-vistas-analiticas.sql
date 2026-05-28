-- ==============================================================================
-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)
-- MATERIA:  Gestión de Datos — Prof. Armen Djenanian
-- FASE 3:   Capa Analítica de Explotación — Vistas SQL para Power BI
-- PLATAFORMA: PostgreSQL 15+ (Supabase)
--
-- NOTAS DE ARQUITECTURA:
--
--   IEEE 1366 — Fórmulas correctas:
--     SAIDI = SUM(duracion_minutos) / total_clientes_servidos
--       Minutos totales de interrupción por cada cliente servido.
--     SAIFI = SUM(clientes_afectados) / total_clientes_servidos
--       Cantidad de interrupciones por cada cliente servido.
--     La versión anterior usaba COUNT(interrupciones) para SAIFI (incorrecto)
--     y SUM(duracion * clientes) para SAIDI. Esta versión corrige ambas.
--
--   MED Days (Major Event Days) — IEEE 1366, método 2.5 Beta:
--     El umbral MED se calcula sobre la BASELINE COMPLETA (todos los días con
--     interrupciones), SIN excluir días MED previamente. La versión anterior
--     leía de una vista que ya filtraba excluido_med = FALSE, creando una
--     espiral: el umbral dependía de datos que ya excluían MED.
--     Aquí la función fn_calcular_umbral_med() consulta directamente
--     fact_interrupciones + dim_tiempo + dim_clientes_inventario.
--
--   Aritmética de fechas con INTERVAL:
--     Toda comparación y cálculo de rango temporal usa INTERVAL nativo de
--     PostgreSQL, no aritmética de enteros (anio * 100 + mes).
--
--   Granularidad separada:
--     No se usa GROUPING SETS que mezcla niveles de agregación en un solo
--     resultado sin discriminador. Cada vista opera en un nivel de granularidad
--     explícito. Si se necesita drill-down, se usan vistas separadas o
--     columnas de nivel con GROUPING() para distinguir totales de detalles.
--
--   Sin años hardcodeados:
--     Ninguna vista usa EXTRACT(YEAR FROM NOW()) como filtro fijo. Se usan
--     rangos dinámicos con INTERVAL o se deja el filtrado al consumidor.
-- ==============================================================================


-- =============================================================================
-- FUNCIÓN: Umbral MED (IEEE 1366, método 2.5 Beta) — sobre baseline completa
-- =============================================================================

/*
Algoritmo IEEE 1366-2012, Sección 5.4:
  1. Calcular SAIDI diario para TODO el histórico (sin excluir MED).
  2. Para días con SAIDI > 0: transformación ln(SAIDI).
  3. α = media de los ln, β = desviación estándar poblacional.
  4. T_MED = exp(α + 2.5 × β).
  5. Días con SAIDI > T_MED son Major Event Days.

IMPORTANTE: esta función lee directamente de fact_interrupciones + dimensiones,
NO de vistas que ya excluyan MED. Esto rompe la espiral de dependencia.
*/
CREATE OR REPLACE FUNCTION fn_calcular_umbral_med()
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    WITH saidi_diario_baseline AS (
        SELECT
            dt.timestamp_completo AS fecha,
            COALESCE(SUM(fi.duracion_minutos), 0) AS suma_duracion,
            MAX(ci.total_clientes_servidos) AS total_clientes
        FROM dim_tiempo dt
        JOIN fact_interrupciones fi
            ON fi.sk_tiempo = dt.sk_tiempo
        LEFT JOIN LATERAL (
            SELECT total_clientes_servidos
            FROM dim_clientes_inventario ci
            WHERE ci.fecha_inicio <= dt.timestamp_completo
              AND (ci.fecha_fin IS NULL OR ci.fecha_fin > dt.timestamp_completo)
              AND ci.activo_bool = TRUE
            ORDER BY ci.sk_clientes DESC
            LIMIT 1
        ) ci ON TRUE
        GROUP BY dt.timestamp_completo
        HAVING MAX(ci.total_clientes_servidos) > 0
           AND COALESCE(SUM(fi.duracion_minutos), 0) > 0
    ),
    con_saidi AS (
        SELECT
            fecha,
            ROUND(suma_duracion / total_clientes::NUMERIC, 4) AS saidi_diario
        FROM saidi_diario_baseline
    ),
    log_transform AS (
        SELECT
            LN(saidi_diario) AS ln_saidi
        FROM con_saidi
        WHERE saidi_diario > 0
    ),
    estadisticas AS (
        SELECT
            AVG(ln_saidi) AS alpha,
            STDDEV_POP(ln_saidi) AS beta
        FROM log_transform
    )
    SELECT
        CASE
            WHEN beta IS NULL OR beta = 0 THEN 999999999
            ELSE ROUND(EXP(alpha + 2.5 * beta)::NUMERIC, 2)
        END
    FROM estadisticas;
$$;

COMMENT ON FUNCTION fn_calcular_umbral_med() IS
'Umbral MED (IEEE 1366 método 2.5 Beta). Calculado sobre baseline completa, sin espiral de exclusión.';


-- =============================================================================
-- VISTA: vw_med_threshold — Umbral MED y clasificación de días
-- =============================================================================

/*
Expone el umbral MED y permite clasificar cada día como MED o no-MED.
Se calcula sobre la baseline completa (sin excluir MED previamente).
Power BI puede usar esta vista como referencia para slicers de exclusión.
*/
CREATE OR REPLACE VIEW vw_med_threshold AS
WITH saidi_diario_completo AS (
    SELECT
        dt.timestamp_completo AS fecha,
        dt.anio,
        dt.mes,
        dt.nombre_mes,
        COALESCE(SUM(fi.duracion_minutos), 0) AS suma_duracion,
        MAX(ci.total_clientes_servidos) AS total_clientes,
        COUNT(fi.sk_interrupcion) AS total_interrupciones
    FROM dim_tiempo dt
    JOIN fact_interrupciones fi
        ON fi.sk_tiempo = dt.sk_tiempo
    LEFT JOIN LATERAL (
        SELECT total_clientes_servidos
        FROM dim_clientes_inventario ci
        WHERE ci.fecha_inicio <= dt.timestamp_completo
          AND (ci.fecha_fin IS NULL OR ci.fecha_fin > dt.timestamp_completo)
          AND ci.activo_bool = TRUE
            ORDER BY ci.sk_clientes DESC
        LIMIT 1
    ) ci ON TRUE
    GROUP BY dt.timestamp_completo, dt.anio, dt.mes, dt.nombre_mes
    HAVING MAX(ci.total_clientes_servidos) > 0
)
SELECT
    fecha,
    anio,
    mes,
    nombre_mes,
    total_interrupciones,
    suma_duracion,
    total_clientes,
    CASE
        WHEN total_clientes > 0
        THEN ROUND(suma_duracion / total_clientes::NUMERIC, 4)
        ELSE 0
    END AS saidi_diario,
    fn_calcular_umbral_med() AS umbral_med,
    CASE
        WHEN total_clientes > 0
             AND (suma_duracion / total_clientes::NUMERIC) > fn_calcular_umbral_med()
        THEN TRUE
        ELSE FALSE
    END AS es_med
FROM saidi_diario_completo
WHERE total_interrupciones > 0
ORDER BY fecha DESC;

COMMENT ON VIEW vw_med_threshold IS
'Clasificación MED de cada día. Umbral calculado sobre baseline completa (sin espiral).';


-- =============================================================================
-- VISTA PRINCIPAL: vw_saidi_saifi — SAIDI/SAIFI mensual con jerarquía de red
-- =============================================================================

/*
Vista principal para Power BI. Proporciona SAIDI/SAIFI mensual con drill-down
jerárquico por subestación, circuito y transformador.

Fórmulas IEEE 1366 corregidas:
  SAIDI = SUM(duracion_minutos) / total_clientes_servidos
  SAIFI = SUM(clientes_afectados) / total_clientes_servidos

Excluye días MED usando vw_med_threshold como filtro.
No usa GROUPING SETS: cada fila es granularidad (subestación, circuito,
transformador, mes). Para totales por ciudad, usar vw_tendencia_mensual.
*/
CREATE OR REPLACE VIEW vw_saidi_saifi AS
WITH med_fechas AS (
    SELECT fecha
    FROM vw_med_threshold
    WHERE es_med = TRUE
)
SELECT
    dre.subestacion,
    dre.circuito,
    dre.transformador,
    dt.anio,
    dt.mes,
    dt.nombre_mes,
    dt.trimestre,
    LPAD(dt.anio::TEXT, 4, '0') || '-' || LPAD(dt.mes::TEXT, 2, '0') AS periodo,

    COUNT(fi.sk_interrupcion) AS total_interrupciones,
    COALESCE(SUM(fi.duracion_minutos), 0) AS suma_duracion_minutos,
    COALESCE(SUM(fi.clientes_afectados), 0) AS total_clientes_afectados,

    COALESCE(MAX(ci.total_clientes_servidos), 0) AS total_clientes_servidos,

    CASE
        WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(
            COALESCE(SUM(fi.duracion_minutos), 0)::NUMERIC
            / MAX(ci.total_clientes_servidos)::NUMERIC,
            2
        )
        ELSE 0
    END AS saidi,

    CASE
        WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(
            COALESCE(SUM(fi.clientes_afectados), 0)::NUMERIC
            / MAX(ci.total_clientes_servidos)::NUMERIC,
            4
        )
        ELSE 0
    END AS saifi,

    CASE
        WHEN COUNT(fi.sk_interrupcion) > 0
        THEN ROUND(
            COALESCE(SUM(fi.duracion_minutos), 0)::NUMERIC
            / COUNT(fi.sk_interrupcion)::NUMERIC,
            2
        )
        ELSE 0
    END AS caidi,

    NOW() AS fecha_consulta

FROM fact_interrupciones fi
JOIN dim_tiempo dt
    ON fi.sk_tiempo = dt.sk_tiempo
JOIN dim_red_electrica dre
    ON fi.sk_red_electrica = dre.sk_red_electrica
LEFT JOIN LATERAL (
    SELECT total_clientes_servidos
    FROM dim_clientes_inventario ci
    WHERE ci.fecha_inicio <= dt.timestamp_completo
      AND (ci.fecha_fin IS NULL OR ci.fecha_fin > dt.timestamp_completo)
      AND ci.activo_bool = TRUE
    ORDER BY ci.sk_clientes DESC
    LIMIT 1
) ci ON TRUE
LEFT JOIN med_fechas mf
    ON mf.fecha = dt.timestamp_completo

WHERE fi.excluido_med = FALSE
  AND mf.fecha IS NULL

GROUP BY
    dre.subestacion,
    dre.circuito,
    dre.transformador,
    dt.anio, dt.mes, dt.nombre_mes, dt.trimestre, periodo

ORDER BY dt.anio DESC, dt.mes DESC, dre.subestacion;

COMMENT ON VIEW vw_saidi_saifi IS
'SAIDI/SAIFI/CAIDI mensual por subestación/circuito/transformador. Sin GROUPING SETS. Excluye MED.';


-- =============================================================================
-- VISTA: vw_tendencia_mensual — Tendencia SAIDI/SAIFI a nivel ciudad
-- =============================================================================

/*
Tendencia mensual a nivel ciudad (sin desglose por red) para gráficos de línea.
Usa INTERVAL nativo para el rango de últimos 24 meses, no aritmética de enteros.
Incluye variación porcentual intermensual con LAG().
*/
CREATE OR REPLACE VIEW vw_tendencia_mensual AS
WITH med_fechas AS (
    SELECT fecha
    FROM vw_med_threshold
    WHERE es_med = TRUE
),
mensual_ciudad AS (
    SELECT
        dt.anio,
        dt.mes,
        dt.nombre_mes,
        dt.trimestre,
        LPAD(dt.anio::TEXT, 4, '0') || '-' || LPAD(dt.mes::TEXT, 2, '0') AS periodo,
        (dt.anio * 100 + dt.mes)::INTEGER AS periodo_orden,
        COUNT(fi.sk_interrupcion) AS total_interrupciones,
        COALESCE(SUM(fi.clientes_afectados), 0) AS total_clientes_afectados,
        COALESCE(SUM(fi.duracion_minutos), 0) AS suma_duracion_minutos,
        COALESCE(MAX(ci.total_clientes_servidos), 0) AS total_clientes_servidos
    FROM dim_tiempo dt
    LEFT JOIN fact_interrupciones fi
        ON fi.sk_tiempo = dt.sk_tiempo
        AND fi.excluido_med = FALSE
    LEFT JOIN med_fechas mf
        ON mf.fecha = dt.timestamp_completo
    LEFT JOIN LATERAL (
        SELECT total_clientes_servidos
        FROM dim_clientes_inventario ci
        WHERE ci.fecha_inicio <= dt.timestamp_completo
          AND (ci.fecha_fin IS NULL OR ci.fecha_fin > dt.timestamp_completo)
          AND ci.activo_bool = TRUE
            ORDER BY ci.sk_clientes DESC
        LIMIT 1
    ) ci ON TRUE
    WHERE mf.fecha IS NULL
    GROUP BY dt.anio, dt.mes, dt.nombre_mes, dt.trimestre
)
SELECT
    anio,
    mes,
    nombre_mes,
    trimestre,
    periodo,
    periodo_orden,
    total_interrupciones,
    total_clientes_afectados,
    suma_duracion_minutos,
    total_clientes_servidos,

    CASE
        WHEN total_clientes_servidos > 0
        THEN ROUND(suma_duracion_minutos::NUMERIC / total_clientes_servidos::NUMERIC, 2)
        ELSE 0
    END AS saidi_ciudad,

    CASE
        WHEN total_clientes_servidos > 0
        THEN ROUND(total_clientes_afectados::NUMERIC / total_clientes_servidos::NUMERIC, 4)
        ELSE 0
    END AS saifi_ciudad,

    ROUND(
        (CASE WHEN total_clientes_servidos > 0
              THEN suma_duracion_minutos::NUMERIC / total_clientes_servidos::NUMERIC
              ELSE 0
         END
         - LAG(CASE WHEN total_clientes_servidos > 0
                    THEN suma_duracion_minutos::NUMERIC / total_clientes_servidos::NUMERIC
                    ELSE 0
               END)
           OVER (ORDER BY anio, mes))
        / NULLIF(LAG(CASE WHEN total_clientes_servidos > 0
                          THEN suma_duracion_minutos::NUMERIC / total_clientes_servidos::NUMERIC
                          ELSE 0
                     END)
                  OVER (ORDER BY anio, mes), 0)
        * 100,
        2
    ) AS variacion_saidi_pct

FROM mensual_ciudad
WHERE TO_DATE(anio::TEXT || '-' || LPAD(mes::TEXT, 2, '0'), 'YYYY-MM')
      >= (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '24 months')
ORDER BY anio DESC, mes DESC;

COMMENT ON VIEW vw_tendencia_mensual IS
'Tendencia SAIDI/SAIFI 24 meses a nivel ciudad. INTERVAL para rango dinámico. Para gráficos de línea.';


-- =============================================================================
-- VISTA: vw_ranking_subestaciones — Ranking dinámico sin año hardcodeado
-- =============================================================================

/*
Ranking de subestaciones por SAIDI promedio. No hardcodea EXTRACT(YEAR FROM NOW()):
usa los últimos 12 meses dinámicamente con INTERVAL.
Incluye comparación contra promedio de ciudad y semáforo de desempeño.
*/
CREATE OR REPLACE VIEW vw_ranking_subestaciones AS
WITH med_fechas AS (
    SELECT fecha
    FROM vw_med_threshold
    WHERE es_med = TRUE
),
rango_dinamico AS (
    SELECT
        DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months' AS inicio_rango,
        DATE_TRUNC('month', CURRENT_DATE) AS fin_rango
),
datos_subestacion AS (
    SELECT
        dre.subestacion,
        dt.anio,
        dt.mes,
        LPAD(dt.anio::TEXT, 4, '0') || '-' || LPAD(dt.mes::TEXT, 2, '0') AS periodo,
        COUNT(fi.sk_interrupcion) AS total_interrupciones,
        COALESCE(SUM(fi.duracion_minutos), 0) AS suma_duracion,
        COALESCE(SUM(fi.clientes_afectados), 0) AS total_clientes_afectados,
        COALESCE(MAX(ci.total_clientes_servidos), 0) AS total_clientes_servidos
    FROM fact_interrupciones fi
    JOIN dim_tiempo dt
        ON fi.sk_tiempo = dt.sk_tiempo
    JOIN dim_red_electrica dre
        ON fi.sk_red_electrica = dre.sk_red_electrica
    LEFT JOIN LATERAL (
        SELECT total_clientes_servidos
        FROM dim_clientes_inventario ci
        WHERE ci.fecha_inicio <= dt.timestamp_completo
          AND (ci.fecha_fin IS NULL OR ci.fecha_fin > dt.timestamp_completo)
          AND ci.activo_bool = TRUE
            ORDER BY ci.sk_clientes DESC
        LIMIT 1
    ) ci ON TRUE
    LEFT JOIN med_fechas mf
        ON mf.fecha = dt.timestamp_completo
    CROSS JOIN rango_dinamico rd
    WHERE fi.excluido_med = FALSE
      AND mf.fecha IS NULL
      AND dt.timestamp_completo >= rd.inicio_rango
      AND dt.timestamp_completo < rd.fin_rango
    GROUP BY dre.subestacion, dt.anio, dt.mes
),
metricas_sub AS (
    SELECT
        subestacion,
        COUNT(DISTINCT periodo) AS meses_con_datos,
        ROUND(AVG(
            CASE WHEN total_clientes_servidos > 0
                 THEN suma_duracion::NUMERIC / total_clientes_servidos::NUMERIC
                 ELSE 0
            END
        )::NUMERIC, 2) AS saidi_promedio,
        ROUND(AVG(
            CASE WHEN total_clientes_servidos > 0
                 THEN total_clientes_afectados::NUMERIC / total_clientes_servidos::NUMERIC
                 ELSE 0
            END
        )::NUMERIC, 4) AS saifi_promedio,
        SUM(total_interrupciones) AS total_interrupciones_acum
    FROM datos_subestacion
    GROUP BY subestacion
),
promedio_ciudad AS (
    SELECT ROUND(AVG(saidi_promedio)::NUMERIC, 2) AS saidi_promedio_ciudad
    FROM metricas_sub
)
SELECT
    ROW_NUMBER() OVER (ORDER BY ms.saidi_promedio DESC) AS ranking,
    ms.subestacion,
    ms.meses_con_datos,
    ms.saidi_promedio,
    ms.saifi_promedio,
    ms.total_interrupciones_acum,
    pc.saidi_promedio_ciudad,
    ROUND(ms.saidi_promedio - pc.saidi_promedio_ciudad, 2) AS delta_vs_ciudad,
    CASE
        WHEN ms.saidi_promedio > pc.saidi_promedio_ciudad * 2.0 THEN 'CRITICO'
        WHEN ms.saidi_promedio > pc.saidi_promedio_ciudad * 1.5 THEN 'ALTO'
        WHEN ms.saidi_promedio > pc.saidi_promedio_ciudad       THEN 'MEDIO'
        ELSE 'NORMAL'
    END AS nivel_desempeno
FROM metricas_sub ms
CROSS JOIN promedio_ciudad pc
ORDER BY ranking;

COMMENT ON VIEW vw_ranking_subestaciones IS
'Ranking de subestaciones por SAIDI. Rango dinámico (últimos 12 meses con INTERVAL). Sin año hardcodeado.';


-- =============================================================================
-- VISTA: vw_interrupciones_por_criticidad — Interrupciones por nivel de criticidad
-- =============================================================================

/*
Agrega interrupciones por nivel de criticidad de la zona geográfica.
Permite identificar si las zonas CRITICAS tienen más interrupciones que
las zonas NORMAL, informando decisiones de inversión en infraestructura.
*/
CREATE OR REPLACE VIEW vw_interrupciones_por_criticidad AS
WITH med_fechas AS (
    SELECT fecha
    FROM vw_med_threshold
    WHERE es_med = TRUE
)
SELECT
    dg.nivel_criticidad,
    dt.anio,
    dt.mes,
    LPAD(dt.anio::TEXT, 4, '0') || '-' || LPAD(dt.mes::TEXT, 2, '0') AS periodo,
    COUNT(fi.sk_interrupcion) AS total_interrupciones,
    COALESCE(SUM(fi.duracion_minutos), 0) AS suma_duracion_minutos,
    COALESCE(SUM(fi.clientes_afectados), 0) AS total_clientes_afectados,
    ROUND(AVG(fi.duracion_minutos)::NUMERIC, 2) AS duracion_promedio,
    COUNT(DISTINCT dg.sector_urbano) AS sectores_afectados
FROM fact_interrupciones fi
JOIN dim_tiempo dt
    ON fi.sk_tiempo = dt.sk_tiempo
JOIN dim_geografia_urbana dg
    ON fi.sk_geografia_urbana = dg.sk_geografia_urbana
LEFT JOIN med_fechas mf
    ON mf.fecha = dt.timestamp_completo
WHERE fi.excluido_med = FALSE
  AND mf.fecha IS NULL
GROUP BY dg.nivel_criticidad, dt.anio, dt.mes
ORDER BY dt.anio DESC, dt.mes DESC,
    CASE dg.nivel_criticidad
        WHEN 'CRITICO' THEN 1
        WHEN 'ALTO'    THEN 2
        WHEN 'MEDIO'   THEN 3
        WHEN 'NORMAL'  THEN 4
        WHEN 'BAJO'    THEN 5
    END;

COMMENT ON VIEW vw_interrupciones_por_criticidad IS
'Interrupciones por nivel de criticidad geográfica. Para análisis de inversión en infraestructura.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Heatmap de interrupciones por hora y día de semana
-- =============================================================================

/*
Patrón temporal: ¿las interrupciones ocurren más en hora pico (18-21h)?
Formato matricial (hora × día_semana) para heatmap en Power BI.
Usa timestamp_inicio de fact_interrupciones para extraer la hora.
*/
CREATE OR REPLACE VIEW vw_heatmap_interrupciones AS
SELECT
    EXTRACT(HOUR FROM fi.timestamp_inicio)::SMALLINT AS hora,
    dt.dia_semana,
    dt.dia_semana_num,
    CASE
        WHEN EXTRACT(HOUR FROM fi.timestamp_inicio) BETWEEN 6 AND 11  THEN 'Manana'
        WHEN EXTRACT(HOUR FROM fi.timestamp_inicio) BETWEEN 12 AND 17 THEN 'Tarde'
        WHEN EXTRACT(HOUR FROM fi.timestamp_inicio) BETWEEN 18 AND 22 THEN 'Pico'
        ELSE 'Noche'
    END AS franja_horaria,
    COUNT(fi.sk_interrupcion) AS total_interrupciones,
    ROUND(AVG(fi.duracion_minutos)::NUMERIC, 2) AS duracion_promedio,
    SUM(fi.duracion_minutos) AS duracion_total
FROM fact_interrupciones fi
JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
WHERE fi.excluido_med = FALSE
GROUP BY
    EXTRACT(HOUR FROM fi.timestamp_inicio)::SMALLINT,
    dt.dia_semana, dt.dia_semana_num, franja_horaria
ORDER BY dt.dia_semana_num, hora;

COMMENT ON VIEW vw_heatmap_interrupciones IS
'Heatmap de interrupciones por hora x dia de semana. Para Power BI matrix visual.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Auditoría de errores (err_telemetria)
-- =============================================================================

/*
Dashboard de calidad de datos. Evolución de eventos huérfanos y corruptos.
Tendencia creciente = problema sistémico en ingesta o medidores.
*/
CREATE OR REPLACE VIEW vw_auditoria_errores AS
SELECT
    DATE_TRUNC('day', fecha_deteccion)::DATE AS fecha,
    motivo_error,
    COUNT(*) AS total_errores,
    COUNT(DISTINCT id_medidor) AS medidores_afectados,
    SUM(CASE WHEN resuelto THEN 1 ELSE 0 END) AS resueltos,
    SUM(CASE WHEN NOT resuelto THEN 1 ELSE 0 END) AS pendientes
FROM err_telemetria
GROUP BY DATE_TRUNC('day', fecha_deteccion)::DATE, motivo_error
ORDER BY fecha DESC, total_errores DESC;

COMMENT ON VIEW vw_auditoria_errores IS
'Auditoría de calidad de datos. Tendencia de errores en telemetría.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Monitoreo ELT (lotes de procesamiento)
-- =============================================================================

/*
Dashboard operacional: salud del pipeline ELT.
*/
CREATE OR REPLACE VIEW vw_monitoreo_elt AS
SELECT
    id_lote,
    fecha_inicio,
    fecha_fin,
    fecha_ejecucion,
    total_eventos,
    total_hechos,
    total_huerfanos,
    total_transitorios,
    estado,
    duracion_segundos,
    CASE
        WHEN total_eventos > 0
        THEN ROUND((total_hechos::NUMERIC / total_eventos::NUMERIC) * 100, 2)
        ELSE 0
    END AS tasa_conversion_pct,
    CASE
        WHEN total_eventos > 0
        THEN ROUND((total_huerfanos::NUMERIC / total_eventos::NUMERIC) * 100, 2)
        ELSE 0
    END AS tasa_error_pct
FROM ctrl_lotes_procesamiento
ORDER BY id_lote DESC;

COMMENT ON VIEW vw_monitoreo_elt IS
'Monitoreo de pipelines ELT. Salud operacional del sistema de ingesta.';


-- =============================================================================
-- FUNCIÓN AUXILIAR: Marcar días MED en fact_interrupciones (batch)
-- =============================================================================

/*
Actualiza excluido_med en fact_interrupciones para días clasificados como MED.
Ejecutar después de cada lote de reconciliación o como tarea programada.
*/
CREATE OR REPLACE FUNCTION fn_actualizar_flag_med()
RETURNS TABLE(
    total_actualizados INTEGER,
    total_med_days     INTEGER,
    umbral_aplicado    NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_umbral    NUMERIC;
    v_med_days  INTEGER;
    v_afectados INTEGER;
BEGIN
    v_umbral := fn_calcular_umbral_med();

    SELECT COUNT(*) INTO v_med_days
    FROM vw_med_threshold
    WHERE es_med = TRUE;

    WITH med_fechas AS (
        SELECT fecha
        FROM vw_med_threshold
        WHERE es_med = TRUE
    )
    UPDATE fact_interrupciones fi
    SET excluido_med = TRUE
    FROM dim_tiempo dt
    JOIN med_fechas mf ON mf.fecha = dt.timestamp_completo
    WHERE fi.sk_tiempo = dt.sk_tiempo
      AND fi.excluido_med = FALSE;

    GET DIAGNOSTICS v_afectados = ROW_COUNT;

    RETURN QUERY
    SELECT v_afectados, v_med_days, v_umbral;
END;
$$;

COMMENT ON FUNCTION fn_actualizar_flag_med() IS
'Actualiza flag excluido_med en fact_interrupciones basado en umbral MED actual.';


-- =============================================================================
-- RESUMEN DE VISTAS PARA POWER BI
-- =============================================================================

/*
Orden de importación en Power BI:

  1. vw_saidi_saifi                  → Dashboard principal (KPI, barras, drill-down)
  2. vw_med_threshold                → Tabla de referencia MED + slicer
  3. vw_tendencia_mensual            → Gráfico de línea (tendencia SAIDI)
  4. vw_ranking_subestaciones        → Tabla de ranking con semáforo
  5. vw_interrupciones_por_criticidad → Análisis por zona geográfica
  6. vw_heatmap_interrupciones       → Matrix visual (hora × día)
  7. vw_auditoria_errores            → Dashboard de calidad de datos
  8. vw_monitoreo_elt                → Dashboard operacional

Relaciones en Power BI:
  - vw_saidi_saifi[periodo] → vw_tendencia_mensual[periodo]
  - vw_saidi_saifi[subestacion] → vw_ranking_subestaciones[subestacion]
  - vw_saidi_saifi[nivel_criticidad] → vw_interrupciones_por_criticidad[nivel_criticidad]
*/
