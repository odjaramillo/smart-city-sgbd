-- ==============================================================================
-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)
-- MATERIA:  Gestión de Datos — Prof. Armen Djenanian
-- FASE 3:   Capa Analítica de Explotación — Vistas SQL para Power BI
-- PLATAFORMA: Supabase (PostgreSQL 15+)
--
-- NOTAS DE ARQUITECTURA (embebidas como comentarios):
--
--   Todas las vistas están diseñadas para ser importadas directamente en Power BI
--   sin transformaciones adicionales en Power Query. Esto sigue el principio de
--   "ELT over ETL": la base de datos hace el trabajo pesado y Power BI solo
--   renderiza. Las vistas son SELECT simples sin CTEs recursivos, LATERAL JOINs
--   ni funciones de ventana complejas que Power BI no pueda plegar (query folding).
--
--   Denominador dinámico (SCD Tipo 2):
--     Cada vista analítica resuelve el total de clientes servidos al momento
--     exacto de la interrupción mediante JOIN con dim_clientes_inventario usando
--     el rango de vigencia [fecha_inicio, fecha_fin). Esto garantiza que un SAIDI
--     de 2023 use el total de clientes de 2023, no el actual.
--
--     Para agregaciones diarias/mensuales, se toma el total_clientes_servidos de
--     la primera interrupción del período (que corresponde al inventario activo
--     en ese momento). En la práctica, el inventario de clientes no cambia
--     intra-día, por lo que esta aproximación es exacta a nivel diario.
--
--   MED Days (Major Event Days) — IEEE 1366, método 2.5 Beta:
--     Los MED son días con interrupciones catastróficas (tormentas, apagones
--     nacionales) que distorsionarían los indicadores rutinarios. El estándar
--     IEEE 1366 establece que estos días deben identificarse estadísticamente y
--     excluirse de los reportes de desempeño rutinario.
--
--     El algoritmo implementado:
--       1. Calcular SAIDI diario para todo el histórico.
--       2. Tomar ln(SAIDI + 1) para cada día con SAIDI > 0.
--       3. α = media de los ln, β = desviación estándar de los ln.
--       4. Umbral T_MED = exp(α + 2.5 × β) - 1.
--       5. Cualquier día con SAIDI > T_MED es MED.
--
--     La función fn_calcular_umbral_med() implementa este cálculo de forma
--     dinámica: se recalcula cada vez que se consulta la vista, reflejando
--     automáticamente nuevos datos y cambios en la distribución.
-- ==============================================================================


-- =============================================================================
-- VISTA BASE: SAIDI y SAIFI diario con denominador dinámico SCD Tipo 2
-- =============================================================================

/*
Esta vista es la base atómica para todas las agregaciones posteriores.
Cada fila representa un día calendario con:
  - saidi_diario: Σ(duración × clientes_afectados) / total_clientes_servidos
  - saifi_diario: Σ(clientes_afectados) / total_clientes_servidos

El JOIN con dim_clientes_inventario resuelve el denominador correcto para
cada fecha usando la ventana de vigencia del SCD Tipo 2.

El JOIN con dim_tiempo permite filtrar por año/mes/trimestre en Power BI
sin necesidad de cálculos adicionales.
*/
CREATE OR REPLACE VIEW vw_saidi_saifi_diario AS
SELECT
    dt.anio,
    dt.mes,
    dt.nombre_mes,
    dt.trimestre,
    dt.dia,
    dt.timestamp_completo::DATE                              AS fecha,

    -- NUEVO: Atributos de tipo de evento (para slicers en Power BI)
    dte.categoria,
    dte.severidad,
    dte.es_critico,

    -- Métricas de interrupción
    COUNT(fi.sk_interrupcion)                                AS total_interrupciones,
    COALESCE(SUM(fi.duracion_minutos * fi.clientes_afectados), 0)
        AS suma_minutos_cliente,

    -- Denominador dinámico: total de clientes servidos en esa fecha
    -- (SCD Tipo 2: buscamos la fila del inventario activa en ese momento)
    MAX(ci.total_clientes_servidos)                          AS total_clientes_servidos,

    -- SAIDI diario = Σ(duración × clientes_afectados) / total_clientes_servidos
    CASE
        WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(
            COALESCE(SUM(fi.duracion_minutos * fi.clientes_afectados), 0)
            / MAX(ci.total_clientes_servidos)::NUMERIC,
            4
        )
        ELSE 0
    END                                                      AS saidi_diario,

    -- SAIFI diario = Σ(clientes_afectados) / total_clientes_servidos
    CASE
        WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(
            COUNT(fi.sk_interrupcion)::NUMERIC
            / MAX(ci.total_clientes_servidos)::NUMERIC,
            4
        )
        ELSE 0
    END                                                      AS saifi_diario

FROM dim_tiempo dt
LEFT JOIN fact_interrupciones fi
    ON fi.sk_tiempo = dt.sk_tiempo
    AND fi.excluido_med = FALSE
LEFT JOIN dim_tipo_evento dte
    ON fi.sk_tipo_evento = dte.sk_tipo_evento
LEFT JOIN dim_clientes_inventario ci
    ON ci.fecha_inicio <= dt.timestamp_completo
    AND (ci.fecha_fin IS NULL OR ci.fecha_fin > dt.timestamp_completo)
    AND ci.activo_bool = TRUE

GROUP BY
    dt.anio, dt.mes, dt.nombre_mes, dt.trimestre,
    dt.dia, dt.timestamp_completo::DATE,
    dte.categoria, dte.severidad, dte.es_critico

ORDER BY fecha DESC;

COMMENT ON VIEW vw_saidi_saifi_diario IS
'SAIDI/SAIFI diario base con denominador SCD Tipo 2. JOIN dim_tipo_evento para filtrado por severidad.';


-- =============================================================================
-- NUEVA VISTA: Agregación diaria de consumo energético por geography
-- =============================================================================

/*
Vista analítica para consumo energético con drill-down por geografía.
Usa GROUPING SETS para permitir agregación multinivel:
  - Nivel completo: subestacion + circuito + sector_urbano
  - Nivel circuito: subestacion + circuito
  - Nivel subestacion: subestacion
  - Nivel ciudad: solo fecha

El campo fecha se incluye explícitamente en cada nivel para que Power BI
pueda filtrar por rango de fechas sin ambigüedad.
*/
CREATE OR REPLACE VIEW vw_consumo_diario AS
SELECT
    dt.anio,
    dt.mes,
    dt.dia,
    dt.timestamp_completo::DATE                              AS fecha,
    dre.subestacion,
    dre.circuito,
    dgu.sector_urbano,
    COUNT(ft.sk_telemetria)                                  AS total_lecturas,
    SUM(ft.consumo_kwh)                                     AS consumo_total_kwh,
    AVG(ft.consumo_kwh)                                     AS consumo_promedio_kwh,
    MAX(ft.consumo_kwh)                                     AS consumo_maximo_kwh,
    MIN(ft.consumo_kwh)                                     AS consumo_minimo_kwh
FROM fact_telemetria ft
JOIN dim_tiempo dt ON ft.sk_tiempo = dt.sk_tiempo
JOIN dim_red_electrica dre ON ft.sk_red_electrica = dre.sk_red_electrica
JOIN dim_geografia_urbana dgu ON ft.sk_geografia_urbana = dgu.sk_geografia_urbana
GROUP BY
    GROUPING SETS (
        (dt.anio, dt.mes, dt.dia, fecha, dre.subestacion, dre.circuito, dgu.sector_urbano),
        (dt.anio, dt.mes, dt.dia, fecha, dre.subestacion, dre.circuito),
        (dt.anio, dt.mes, dt.dia, fecha, dre.subestacion),
        (dt.anio, dt.mes, dt.dia, fecha)
    )
ORDER BY fecha DESC;

COMMENT ON VIEW vw_consumo_diario IS
'Agregación diaria de consumo por geografía. Drill-down: fecha → subestacion → circuito → sector_urbano.';


-- =============================================================================
-- NUEVA VISTA: Tendencia de voltaje por transformador con detección de anomalías
-- =============================================================================

/*
Vista analítica para monitoreo de calidad de voltaje.
Detecta transformadores con fluctuación excesiva (desviación > 5% del promedio).
Usa GROUPING SETS para agregación multinivel por geografía:
  - Nivel transformador: subestacion + circuito + transformador
  - Nivel circuito: subestacion + circuito
  - Nivel subestacion: subestacion
  - Nivel mes: solo anio + mes

El flag fluctuacion_excesiva permite filtrar en Power BI para identificar
transformadores que requieren mantenimiento correctivo.
*/
CREATE OR REPLACE VIEW vw_voltaje_tendencia AS
SELECT
    dt.anio,
    dt.mes,
    dre.subestacion,
    dre.circuito,
    dre.transformador,
    COUNT(ft.sk_telemetria)                                  AS total_lecturas,
    ROUND(AVG(ft.voltaje)::NUMERIC, 2)                       AS voltaje_promedio,
    ROUND(STDDEV(ft.voltaje)::NUMERIC, 2)                    AS voltaje_desviacion,
    MIN(ft.voltaje)                                          AS voltaje_minimo,
    MAX(ft.voltaje)                                          AS voltaje_maximo,
    CASE
        WHEN STDDEV(ft.voltaje) / NULLIF(AVG(ft.voltaje), 0) > 0.05
        THEN TRUE ELSE FALSE
    END                                                      AS fluctuacion_excesiva
FROM fact_telemetria ft
JOIN dim_tiempo dt ON ft.sk_tiempo = dt.sk_tiempo
JOIN dim_red_electrica dre ON ft.sk_red_electrica = dre.sk_red_electrica
GROUP BY
    GROUPING SETS (
        (dt.anio, dt.mes, dre.subestacion, dre.circuito, dre.transformador),
        (dt.anio, dt.mes, dre.subestacion, dre.circuito),
        (dt.anio, dt.mes, dre.subestacion),
        (dt.anio, dt.mes)
    )
ORDER BY dt.anio DESC, dt.mes DESC;

COMMENT ON VIEW vw_voltaje_tendencia IS
'Tendencia de voltaje por transformador. Flag fluctuacion_excesiva para alertas de mantenimiento.';


-- =============================================================================
-- FUNCIÓN: Cálculo del umbral MED (IEEE 1366, método 2.5 Beta)
-- =============================================================================

/*
Implementación del algoritmo estadístico de la IEEE 1366-2012, Sección 5.4:

  1. Recolectar SAIDI diario para el período de referencia (todo el histórico).
  2. Excluir días con SAIDI = 0 (sin interrupciones).
  3. Transformación logarítmica: ln(SAIDI) para días con SAIDI > 0.
  4. Calcular media (α) y desviación estándar poblacional (β) de los logaritmos.
  5. Umbral T_MED = exp(α + 2.5 × β).
  6. Días con SAIDI > T_MED se clasifican como Major Event Days.

El factor 2.5 es el recomendado por IEEE para sistemas de distribución
eléctrica. En implementaciones más avanzadas, este factor puede calibrarse
con datos históricos de eventos conocidos.

La función es STABLE (no VOLATILE): para los mismos datos de entrada,
siempre devuelve el mismo resultado dentro de una transacción. Esto permite
que el planificador de PostgreSQL la optimice en subconsultas.
*/
CREATE OR REPLACE FUNCTION fn_calcular_umbral_med()
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    WITH diario_con_interrupciones AS (
        SELECT
            saidi_diario,
            LN(NULLIF(saidi_diario, 0) + 0.0001) AS ln_saidi
            /*
            Se suma 0.0001 para evitar ln(0) = -∞ en días sin interrupciones.
            Como filtramos SAIDI > 0 abajo, esto nunca se aplica a los datos
            usados en el cálculo estadístico. Es una defensa en profundidad
            (defense in depth).
            */
        FROM vw_saidi_saifi_diario
        WHERE saidi_diario > 0
    ),
    estadisticas AS (
        SELECT
            AVG(ln_saidi)                        AS alpha,
            STDDEV_POP(ln_saidi)                 AS beta
        FROM diario_con_interrupciones
    )
    SELECT
        CASE
            WHEN beta IS NULL OR beta = 0 THEN 0
            /*
            Si no hay suficiente variabilidad (ej. solo 1 día con interrupciones),
            el umbral es 0. Esto significa que no se clasifica ningún día como MED,
            lo cual es conservador y evita falsos positivos con pocos datos.
            */
            ELSE ROUND(EXP(alpha + 2.5 * beta)::NUMERIC, 2)
        END
    FROM estadisticas;
$$;

COMMENT ON FUNCTION fn_calcular_umbral_med() IS
'Umbral MED (Major Event Days) según IEEE 1366 método 2.5 Beta. Dinámico.';


-- =============================================================================
-- VISTA: SAIDI/SAIFI diario con clasificación MED
-- =============================================================================

/*
Extiende vw_saidi_saifi_diario agregando:
  - es_med: BOOLEAN que indica si el día supera el umbral MED.
  - umbral_med: valor del umbral calculado para referencia.

Esta vista puede importarse directamente en Power BI. El campo es_med
permite crear un slicer/filtro para que el usuario decida si incluir o
excluir los Major Event Days del análisis.
*/
CREATE OR REPLACE VIEW vw_saidi_saifi_con_med AS
SELECT
    d.*,
    fn_calcular_umbral_med()                         AS umbral_med,
    d.saidi_diario > fn_calcular_umbral_med()        AS es_med
FROM vw_saidi_saifi_diario d
ORDER BY d.fecha DESC;

COMMENT ON VIEW vw_saidi_saifi_con_med IS
'SAIDI/SAIFI diario con bandera MED. Usar con slicer en Power BI.';


-- =============================================================================
-- VISTA PRINCIPAL PARA POWER BI: SAIDI/SAIFI mensual con jerarquía de red
-- =============================================================================

/*
Esta es la vista principal que Power BI importa para los dashboards tácticos
y estratégicos. Proporciona:

  - Agregación mensual de SAIDI/SAIFI.
  - Drill-down jerárquico: Subestación → Circuito → Mes.
  - Columnas de texto para segmentación (slicers) en Power BI.
  - Filtro de MED integrado: la vista excluye automáticamente los MED days.

  ¿Por qué monthly y no diario?
    - SAIDI/SAIFI son indicadores tácticos/estratégicos, no operacionales.
      La granularidad mensual es el estándar en reportes regulatorios.
    - Power BI maneja mejor tablas agregadas con < 100k filas que vistas
      con millones de filas diarias. Si el usuario necesita drill-down a día,
      puede usar vw_saidi_saifi_con_med como tabla secundaria.

  Columna `periodo` en formato YYYY-MM:
    - Power BI puede ordenarla cronológicamente y usarla como eje X en
      gráficos de tendencia.
    - El formato string YYYY-MM garantiza orden lexicográfico = orden
      cronológico, evitando configuraciones adicionales en Power Query.
*/
CREATE OR REPLACE VIEW vw_saidi_saifi_mensual AS
WITH med_days AS (
    -- Identificar días MED usando la función de umbral
    SELECT
        fecha,
        CASE WHEN saidi_diario > fn_calcular_umbral_med()
             THEN TRUE ELSE FALSE
        END AS es_med
    FROM vw_saidi_saifi_diario
    WHERE saidi_diario > 0
),
hechos_filtrados AS (
    -- Excluir interrupciones ocurridas en días MED
    SELECT
        fi.sk_interrupcion,
        fi.sk_tiempo,
        fi.sk_red_electrica,
        fi.sk_clientes,
        fi.duracion_minutos,
        fi.clientes_afectados
    FROM fact_interrupciones fi
    JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
    LEFT JOIN med_days md ON md.fecha = dt.timestamp_completo::DATE
    WHERE fi.excluido_med = FALSE
      AND (md.es_med IS NULL OR md.es_med = FALSE)
      /*
      md.es_med IS NULL cubre días sin interrupciones (no están en med_days).
      Estos no son MED, así que se incluyen (no hay nada que excluir).
      */
)
SELECT
    -- ==================================================================
    -- Columnas de jerarquía de red (para drill-down en Power BI)
    -- ==================================================================
    dre.subestacion,
    dre.circuito,
    dre.transformador,

    -- ==================================================================
    -- Columnas temporales (para segmentación y tendencia)
    -- ==================================================================
    dt.anio,
    dt.mes,
    dt.nombre_mes,
    dt.trimestre,
    -- Período en formato YYYY-MM para eje X ordenable lexicográficamente
    LPAD(dt.anio::TEXT, 4, '0') || '-' || LPAD(dt.mes::TEXT, 2, '0') AS periodo,

    -- ==================================================================
    -- Métricas agregadas mensuales
    -- ==================================================================
    COUNT(hf.sk_interrupcion)                                AS total_interrupciones,
    COALESCE(SUM(hf.duracion_minutos), 0)                    AS suma_duracion_minutos,
    COALESCE(SUM(hf.duracion_minutos * hf.clientes_afectados), 0)
        AS suma_minutos_cliente,
    COALESCE(SUM(hf.clientes_afectados), 0)                  AS total_clientes_afectados,

    -- Denominador: total_clientes_servidos al momento de la primera interrupción del mes
    -- (aproximación válida: el inventario de clientes no cambia intra-mes significativamente)
    COALESCE(MAX(ci.total_clientes_servidos), 0)             AS total_clientes_servidos,

    -- ==================================================================
    -- SAIDI mensual (minutos de interrupción por cliente servido)
    -- ==================================================================
    CASE
        WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(
            COALESCE(SUM(hf.duracion_minutos * hf.clientes_afectados), 0)::NUMERIC
            / MAX(ci.total_clientes_servidos)::NUMERIC,
            2
        )
        ELSE 0
    END                                                      AS saidi,

    -- ==================================================================
    -- SAIFI mensual (interrupciones por cliente servido)
    -- ==================================================================
    CASE
        WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(
            COUNT(hf.sk_interrupcion)::NUMERIC
            / MAX(ci.total_clientes_servidos)::NUMERIC,
            4
        )
        ELSE 0
    END                                                      AS saifi,

    -- ==================================================================
    -- CAIDI mensual (duración promedio por interrupción)
    -- ==================================================================
    CASE
        WHEN COUNT(hf.sk_interrupcion) > 0
        THEN ROUND(
            COALESCE(SUM(hf.duracion_minutos), 0)::NUMERIC
            / COUNT(hf.sk_interrupcion)::NUMERIC,
            2
        )
        ELSE 0
    END                                                      AS caidi,

    -- ==================================================================
    -- Metadatos de actualización
    -- ==================================================================
    NOW()                                                    AS fecha_consulta

FROM hechos_filtrados hf
JOIN dim_tiempo dt
    ON hf.sk_tiempo = dt.sk_tiempo
JOIN dim_red_electrica dre
    ON hf.sk_red_electrica = dre.sk_red_electrica
LEFT JOIN dim_clientes_inventario ci
    ON hf.sk_clientes = ci.sk_clientes

GROUP BY
    GROUPING SETS (
        -- Drill-down jerárquico: Power BI puede navegar entre estos niveles
        (dre.subestacion, dre.circuito, dre.transformador, dt.anio, dt.mes, dt.nombre_mes, dt.trimestre, periodo),
        (dre.subestacion, dre.circuito, dt.anio, dt.mes, dt.nombre_mes, dt.trimestre, periodo),
        (dre.subestacion, dt.anio, dt.mes, dt.nombre_mes, dt.trimestre, periodo),
        (dt.anio, dt.mes, dt.nombre_mes, dt.trimestre, periodo)
        /*
        GROUPING SETS genera múltiples niveles de agregación en una sola pasada.
        Power BI puede usar esta vista con filtros de nivel superior y el
        query folding nativo de PostgreSQL expandirá solo el nivel necesario.

        Ejemplo:
          - Sin filtros → nivel 4 (total por mes), el más agregado.
          - Filtro subestacion = 'SUB-01' → nivel 3.
          - Filtro subestacion = 'SUB-01' AND circuito = 'CIR-NORTE' → nivel 2.
          - Filtro completo hasta transformador → nivel 1.
        */
    )

ORDER BY dt.anio DESC, dt.mes DESC, dre.subestacion;

COMMENT ON VIEW vw_saidi_saifi_mensual IS
'Vista principal para Power BI. SAIDI/SAIFI/CAIDI mensual con jerarquía de red y exclusión MED.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Tendencia de 12 meses (rolling) para gráficos de línea
-- =============================================================================

/*
Power BI necesita una vista con los últimos N períodos para gráficos de
tendencia (line charts). Esta vista siempre devuelve los últimos 24 meses
completos, independientemente de cuándo se consulte.

Se incluye una columna `periodo_orden` numérica (YYYYMM) para que Power BI
pueda ordenar el eje X sin depender del orden lexicográfico del string.
*/
CREATE OR REPLACE VIEW vw_tendencia_12_meses AS
SELECT
    anio,
    mes,
    nombre_mes,
    trimestre,
    periodo,
    (anio * 100 + mes)::INTEGER                              AS periodo_orden,

    -- Métricas a nivel ciudad (sin desglose por red)
    SUM(total_interrupciones)                                AS total_interrupciones,
    SUM(total_clientes_afectados)                            AS total_clientes_afectados,

    -- SAIDI agregado a nivel ciudad
    ROUND(
        SUM(suma_minutos_cliente)::NUMERIC
        / NULLIF(MAX(total_clientes_servidos), 0)::NUMERIC,
        2
    )                                                        AS saidi_ciudad,

    -- SAIFI agregado a nivel ciudad
    ROUND(
        SUM(total_clientes_afectados)::NUMERIC
        / NULLIF(MAX(total_clientes_servidos), 0)::NUMERIC,
        4
    )                                                        AS saifi_ciudad,

    -- Variación porcentual respecto al mes anterior
    ROUND(
        (SUM(suma_minutos_cliente)::NUMERIC
         / NULLIF(MAX(total_clientes_servidos), 0)::NUMERIC
         - LAG(SUM(suma_minutos_cliente)::NUMERIC
               / NULLIF(MAX(total_clientes_servidos), 0)::NUMERIC)
           OVER (ORDER BY anio, mes))
        / NULLIF(LAG(SUM(suma_minutos_cliente)::NUMERIC
                      / NULLIF(MAX(total_clientes_servidos), 0)::NUMERIC)
                  OVER (ORDER BY anio, mes), 0)
        * 100,
        2
    )                                                        AS variacion_saidi_pct

FROM vw_saidi_saifi_mensual
WHERE (anio * 100 + mes) >= (
    -- Últimos 24 meses calculados dinámicamente desde la fecha máxima de interrupción
    SELECT EXTRACT(YEAR FROM val)::INTEGER * 100 + EXTRACT(MONTH FROM val)::INTEGER
    FROM (
        SELECT COALESCE(MAX(timestamp_inicio), NOW()) - INTERVAL '24 months' AS val 
        FROM fact_interrupciones
    ) q
)
GROUP BY anio, mes, nombre_mes, trimestre, periodo
ORDER BY anio DESC, mes DESC;

COMMENT ON VIEW vw_tendencia_12_meses IS
'Tendencia SAIDI/SAIFI 24 meses con variación intermensual. Para gráficos de línea en Power BI.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Ranking de subestaciones por desempeño
-- =============================================================================

/*
Dashboard táctico para identificar las subestaciones con peor desempeño.
Ordenado por SAIDI descendente (mayor duración de interrupción = peor).
Incluye ranking numérico y comparación contra el promedio de la ciudad.
*/
CREATE OR REPLACE VIEW vw_ranking_subestaciones AS
WITH promedio_ciudad AS (
    -- Calcular el SAIDI promedio de toda la ciudad como referencia
    SELECT
        ROUND(AVG(saidi)::NUMERIC, 2) AS saidi_promedio_ciudad
    FROM vw_saidi_saifi_mensual
    WHERE subestacion IS NOT NULL
      AND anio = (
          SELECT COALESCE(EXTRACT(YEAR FROM MAX(timestamp_inicio))::SMALLINT, EXTRACT(YEAR FROM NOW())::SMALLINT)
          FROM fact_interrupciones
      )
)
SELECT
    ROW_NUMBER() OVER (ORDER BY SUM(sm.saidi) DESC)          AS ranking,
    sm.subestacion,
    COUNT(DISTINCT sm.periodo)                               AS meses_con_datos,
    ROUND(AVG(sm.saidi)::NUMERIC, 2)                         AS saidi_promedio,
    ROUND(AVG(sm.saifi)::NUMERIC, 4)                         AS saifi_promedio,
    ROUND(AVG(sm.caidi)::NUMERIC, 2)                         AS caidi_promedio,
    SUM(sm.total_interrupciones)                             AS total_interrupciones_acum,
    pc.saidi_promedio_ciudad,
    -- Delta: cuánto peor (o mejor) está esta subestación vs el promedio de la ciudad
    ROUND(AVG(sm.saidi)::NUMERIC - pc.saidi_promedio_ciudad, 2) AS delta_vs_ciudad,
    -- Clasificación cualitativa para semáforo en Power BI
    CASE
        WHEN AVG(sm.saidi) > pc.saidi_promedio_ciudad * 2.0 THEN 'CRITICO'
        WHEN AVG(sm.saidi) > pc.saidi_promedio_ciudad * 1.5 THEN 'ALTO'
        WHEN AVG(sm.saidi) > pc.saidi_promedio_ciudad       THEN 'MEDIO'
        ELSE 'NORMAL'
    END                                                      AS nivel_desempeno

FROM vw_saidi_saifi_mensual sm
CROSS JOIN promedio_ciudad pc
WHERE sm.subestacion IS NOT NULL
  AND sm.anio = (
      SELECT COALESCE(EXTRACT(YEAR FROM MAX(timestamp_inicio))::SMALLINT, EXTRACT(YEAR FROM NOW())::SMALLINT)
      FROM fact_interrupciones
  )
GROUP BY sm.subestacion, pc.saidi_promedio_ciudad
ORDER BY ranking;

COMMENT ON VIEW vw_ranking_subestaciones IS
'Ranking de subestaciones por SAIDI. Semáforo de desempeño para Power BI.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Heatmap de interrupciones por hora del día y día de semana
-- =============================================================================

/*
Permite identificar patrones temporales: ¿las interrupciones ocurren más
en hora pico (18-21h)? ¿En días hábiles o fines de semana? Esto informa
decisiones de mantenimiento preventivo y dimensionamiento de cuadrillas.

El formato matricial (hora × día_semana) es ideal para un heatmap en Power BI.
*/
CREATE OR REPLACE VIEW vw_heatmap_interrupciones AS
SELECT
    dt.hora,
    dt.dia_semana,
    dt.dia_semana_num,
    CASE
        WHEN dt.hora BETWEEN 6 AND 11  THEN 'Mañana'
        WHEN dt.hora BETWEEN 12 AND 17 THEN 'Tarde'
        WHEN dt.hora BETWEEN 18 AND 22 THEN 'Pico'
        ELSE 'Noche'
    END                                                      AS franja_horaria,
    COUNT(fi.sk_interrupcion)                                AS total_interrupciones,
    ROUND(AVG(fi.duracion_minutos)::NUMERIC, 2)              AS duracion_promedio,
    SUM(fi.duracion_minutos)                                 AS duracion_total
FROM fact_interrupciones fi
JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
WHERE fi.excluido_med = FALSE
GROUP BY dt.hora, dt.dia_semana, dt.dia_semana_num, franja_horaria
ORDER BY dt.dia_semana_num, dt.hora;

COMMENT ON VIEW vw_heatmap_interrupciones IS
'Heatmap de interrupciones por hora × día de semana. Para Power BI matrix visual.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Auditoría de errores (err_telemetria)
-- =============================================================================

/*
Dashboard de calidad de datos. Muestra la evolución de eventos huérfanos
y corruptos a lo largo del tiempo. Si esta vista muestra una tendencia
creciente, indica un problema sistémico en la ingesta (n8n) o en los
medidores (firmware defectuoso, pérdida de paquetes).
*/
CREATE OR REPLACE VIEW vw_auditoria_errores AS
SELECT
    DATE_TRUNC('day', fecha_deteccion)::DATE                 AS fecha,
    motivo_error,
    COUNT(*)                                                 AS total_errores,
    COUNT(DISTINCT id_medidor)                               AS medidores_afectados,
    SUM(CASE WHEN resuelto THEN 1 ELSE 0 END)                AS resueltos,
    SUM(CASE WHEN NOT resuelto THEN 1 ELSE 0 END)            AS pendientes
FROM err_telemetria
GROUP BY DATE_TRUNC('day', fecha_deteccion)::DATE, motivo_error
ORDER BY fecha DESC, total_errores DESC;

COMMENT ON VIEW vw_auditoria_errores IS
'Auditoría de calidad de datos. Tendencia de errores en telemetría para Power BI.';


-- =============================================================================
-- VISTA COMPLEMENTARIA: Lotes de procesamiento (monitoreo ELT)
-- =============================================================================

/*
Dashboard operacional para el equipo de datos. Muestra la salud del pipeline
ELT: frecuencia de ejecución, volumen procesado, tasa de errores y duración.
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
    -- Tasa de conversión: ¿qué porcentaje de eventos staging se convierte en hechos?
    CASE
        WHEN total_eventos > 0
        THEN ROUND((total_hechos::NUMERIC / total_eventos::NUMERIC) * 100, 2)
        ELSE 0
    END                                                      AS tasa_conversion_pct,
    -- Tasa de errores
    CASE
        WHEN total_eventos > 0
        THEN ROUND((total_huerfanos::NUMERIC / total_eventos::NUMERIC) * 100, 2)
        ELSE 0
    END                                                      AS tasa_error_pct
FROM ctrl_lotes_procesamiento
ORDER BY id_lote DESC;

COMMENT ON VIEW vw_monitoreo_elt IS
'Monitoreo de pipelines ELT. Salud operacional del sistema de ingesta.';


-- =============================================================================
-- FUNCIÓN AUXILIAR: Marcar días MED en la tabla de hechos (batch)
-- =============================================================================

/*
Esta función actualiza el campo excluido_med en fact_interrupciones para
todas las interrupciones que ocurrieron en días clasificados como MED.

Se recomienda ejecutarla después de cada lote de reconciliación grande o
como tarea programada semanal. Power BI leerá luego el flag excluido_med
directamente desde la tabla de hechos sin necesidad de recalcular el umbral.

Rendimiento esperado:
  - La función aplica un UPDATE masivo con JOIN sobre la vista diaria.
  - Con índices BRIN sobre timestamp_inicio, el filtro por fecha es O(n)
    donde n = número de días escaneados, no O(m) donde m = total de filas.
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
    -- Calcular el umbral actual
    v_umbral := fn_calcular_umbral_med();

    -- Contar cuántos días superan el umbral
    SELECT COUNT(*) INTO v_med_days
    FROM vw_saidi_saifi_diario
    WHERE saidi_diario > v_umbral;

    -- Marcar las interrupciones de esos días
    WITH med_fechas AS (
        SELECT fecha
        FROM vw_saidi_saifi_diario
        WHERE saidi_diario > v_umbral
    )
    UPDATE fact_interrupciones fi
    SET excluido_med = TRUE
    FROM dim_tiempo dt
    JOIN med_fechas mf ON mf.fecha = dt.timestamp_completo::DATE
    WHERE fi.sk_tiempo = dt.sk_tiempo
      AND fi.excluido_med = FALSE;

    GET DIAGNOSTICS v_afectados = ROW_COUNT;

    RETURN QUERY
    SELECT v_afectados, v_med_days, v_umbral;
END;
$$;

COMMENT ON FUNCTION fn_actualizar_flag_med() IS
'Actualiza el flag excluido_med en fact_interrupciones basado en el umbral MED actual.';


-- =============================================================================
-- RESUMEN DE LAS VISTAS DISPONIBLES PARA POWER BI
-- =============================================================================

/*
Importar en Power BI en este orden (las dependencias se resuelven solas):

  1. vw_saidi_saifi_mensual       → Dashboard principal (KPI, barras, drill-down)
  2. vw_saidi_saifi_con_med       → Tabla de detalle con slicer MED
  3. vw_tendencia_12_meses        → Gráfico de línea (tendencia SAIDI)
  4. vw_ranking_subestaciones     → Tabla de ranking con semáforo
  5. vw_heatmap_interrupciones    → Matrix visual (hora × día)
  6. vw_auditoria_errores         → Dashboard de calidad de datos
  7. vw_monitoreo_elt             → Dashboard operacional (equipo de datos)

  Relaciones en Power BI:
    - vw_saidi_saifi_mensual[periodo] → vw_tendencia_12_meses[periodo]
    - vw_saidi_saifi_mensual[subestacion] → vw_ranking_subestaciones[subestacion]

  Medidas DAX recomendadas (crear en Power BI, no en PostgreSQL):
    - SAIDI YTD:     TOTALYTD([SAIDI], dim_tiempo[fecha])
    - SAIFI YTD:     TOTALYTD([SAIFI], dim_tiempo[fecha])
    - SAIDI vs Meta: [SAIDI] - [Meta SAIDI]
    - % Variación Interanual: DIVIDE([SAIDI] - [SAIDI LY], [SAIDI LY])
*/
