-- ==============================================================================
-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)
-- MATERIA:  Gestión de Datos — Prof. Armen Djenanian
-- FASE 1:   Modelado Dimensional (Metodología Kimball) + Estrategia de Indexación
-- PLATAFORMA: Supabase (PostgreSQL 15+)
--
-- NOTAS DE ARQUITECTURA (embebidas como comentarios):
--   - Modelo en Estrella clásico con una única tabla de hechos atómica y cuatro
--     dimensiones desnormalizadas. Se eligió Estrella sobre Copo de Nieve porque
--     el perfil de carga es 95 % lectura analítica (Power BI) y 5 % escritura ELT.
--     Cada JOIN extra en un Copo de Nieve penaliza el rendimiento de escaneo
--     secuencial sobre fact_interrupciones sin beneficio compensatorio.
--   - Las claves sustitutas (Surrogate Keys) son BIGINT GENERATED ALWAYS AS
--     IDENTITY. Esto desacopla el Data Mart de los IDs operacionales de n8n y
--     permite manejar merges, reasignaciones de medidores y cambios de topología
--     sin romper la integridad referencial de la tabla de hechos.
--   - Índices BRIN (Block Range Index) sobre columnas TIMESTAMPTZ de la tabla de
--     hechos: PostgreSQL almacena las filas en orden de inserción, y dado que el
--     ELT procesa los eventos cronológicamente, la correlación física entre el
--     orden de almacenamiento y timestamp_inicio es altísima. BRIN aprovecha
--     exactamente esta propiedad, ocupando ~1000× menos espacio que un B-Tree
--     equivalente y ofreciendo un rendimiento de filtrado por rango casi idéntico
--     para consultas analíticas que barren grandes ventanas temporales.
--   - dim_clientes_inventario se implementa como SCD Tipo 2 para resolver el
--     problema del denominador dinámico: el total de clientes servidos varía en
--     el tiempo (altas/bajas de servicio, nuevas urbanizaciones). Sin SCD Tipo 2,
--     un SAIDI calculado con el total de clientes actual distorsionaría el
--     indicador histórico. Cada snapshot es válido en un rango [fecha_inicio,
--     fecha_fin) y la condición activo_bool = TRUE identifica el registro vigente.
-- ==============================================================================

-- --------------------------------------------------------------------------
-- ESQUEMA: staging (capa de aterrizaje crudo — poblada por n8n)
-- --------------------------------------------------------------------------

/*
Justificación del staging atómico:
  n8n escribe en staging_eventos sin lógica de negocio. Esto es intencional:
  - Desacopla la ingesta (EL) de la transformación (T). Si n8n falla, el Data
    Mart no se corrompe; solo deja de recibir eventos nuevos.
  - Permite reprocesar históricos desde staging sin depender de la fuente externa.
  - El campo `procesado` actúa como marca de agua para el ELT batch.
*/
CREATE TABLE IF NOT EXISTS staging_eventos (
    id_evento        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_medidor       BIGINT        NOT NULL,
    timestamp_evento TIMESTAMPTZ   NOT NULL,
    tipo_evento      VARCHAR(20)   NOT NULL
        CHECK (tipo_evento IN ('POWER_OUTAGE', 'POWER_RESTORATION')),
    procesado        BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_carga      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Índice compuesto para la consulta de reconciliación: filtra por procesado
-- y ordena por medidor + timestamp para la función de ventana LEAD/LAG.
CREATE INDEX IF NOT EXISTS idx_staging_procesado_medidor_ts
    ON staging_eventos (procesado, id_medidor, timestamp_evento)
    WHERE procesado = FALSE;

COMMENT ON TABLE staging_eventos IS
'Telemetría cruda desde n8n. Sin transformación. Punto de entrada del pipeline ELT.';


-- --------------------------------------------------------------------------
-- ESQUEMA: dwh (Data Warehouse — Modelo en Estrella)
-- --------------------------------------------------------------------------

-- ========================== DIMENSIONES ====================================

/*
Dimensión de Tiempo (dim_tiempo)
  Granularidad: 1 minuto. Esto es necesario porque las interrupciones se miden
  en minutos (IEEE 1366 exige precisión al minuto para el filtro de 5 minutos).
  La jerarquía año → trimestre → mes → día permite drill-down en Power BI sin
  cálculos en tiempo de consulta.

  Estrategia de carga: se precarga masivamente una sola vez con generate_series.
  No se actualiza incrementalmente porque el rango de fechas del proyecto es
  acotado. Para un data mart de producción se usaría un cron trimestral.
*/
CREATE TABLE dim_tiempo (
    sk_tiempo          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    timestamp_completo TIMESTAMPTZ   NOT NULL UNIQUE,
    minuto             SMALLINT      NOT NULL CHECK (minuto BETWEEN 0 AND 59),
    hora               SMALLINT      NOT NULL CHECK (hora BETWEEN 0 AND 23),
    dia                SMALLINT      NOT NULL CHECK (dia BETWEEN 1 AND 31),
    dia_semana         VARCHAR(10)   NOT NULL,
    dia_semana_num     SMALLINT      NOT NULL CHECK (dia_semana_num BETWEEN 1 AND 7),
    semana_anio        SMALLINT      NOT NULL CHECK (semana_anio BETWEEN 1 AND 53),
    mes                SMALLINT      NOT NULL CHECK (mes BETWEEN 1 AND 12),
    nombre_mes         VARCHAR(15)   NOT NULL,
    trimestre          SMALLINT      NOT NULL CHECK (trimestre BETWEEN 1 AND 4),
    anio               SMALLINT      NOT NULL,
    es_fin_semana      BOOLEAN       NOT NULL,
    es_feriado         BOOLEAN       NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE dim_tiempo IS
'Dimensión temporal a granularidad de minuto. Jerarquía: Año → Trimestre → Mes → Día.';

/*
Dimensión Geografía Urbana (dim_geografia_urbana)
  Desnormalizada intencionalmente: sector, distrito y coordenadas viven en una
  sola tabla. Esto evita un JOIN adicional con una tabla de distritos que solo
  aportaría un nombre y una clave foránea. En un modelo estrella puro, las
  dimensiones deben ser "anchas y chatas" (wide & shallow) para minimizar JOINs.

  El campo `nivel_criticidad` permite filtrar el dashboard por zonas de alto
  riesgo (ej. hospitales, centros de datos, estaciones de bomberos).
*/
CREATE TABLE dim_geografia_urbana (
    sk_geografia      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sector_urbano     VARCHAR(100)  NOT NULL,
    distrito          VARCHAR(100)  NOT NULL,
    latitud           NUMERIC(9,6),
    longitud          NUMERIC(9,6),
    nivel_criticidad  VARCHAR(20)   NOT NULL DEFAULT 'NORMAL'
        CHECK (nivel_criticidad IN ('CRITICO', 'ALTO', 'MEDIO', 'NORMAL', 'BAJO')),
    fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE dim_geografia_urbana IS
'Dimensión geográfica desnormalizada. Sector → Distrito con coordenadas y criticidad.';

/*
Dimensión Red Eléctrica (dim_red_electrica)
  Jerarquía explícita en texto plano: Subestación → Circuito → Transformador → Medidor.
  Cada nivel se almacena como columna independiente (no como self-referencing FK)
  para eliminar JOINs recursivos. En Power BI, los filtros de drill-down se
  implementan nativamente sobre columnas de texto sin necesidad de navegar
  árboles de jerarquía.

  `capacidad_kva` y `estado_operativo` son atributos Slowly Changing: cuando un
  transformador se reemplaza o degrada, se inserta una nueva fila con nueva
  surrogate key. La tabla de hechos referencia la SK que estaba vigente en el
  momento de la interrupción.
*/
CREATE TABLE dim_red_electrica (
    sk_red_electrica   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_medidor         BIGINT        NOT NULL,
    id_medidor_origen  BIGINT        NOT NULL,
    codigo_medidor     VARCHAR(50)   NOT NULL,
    transformador      VARCHAR(100)  NOT NULL,
    circuito           VARCHAR(100)  NOT NULL,
    subestacion        VARCHAR(100)  NOT NULL,
    capacidad_kva      NUMERIC(10,2),
    estado_operativo   VARCHAR(30)   NOT NULL DEFAULT 'ACTIVO',
    fecha_inicio       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    fecha_fin          TIMESTAMPTZ,
    activo_bool        BOOLEAN       NOT NULL DEFAULT TRUE,
    fecha_actualizacion TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE dim_red_electrica IS
'Jerarquía de red desnormalizada: Subestación → Circuito → Transformador → Medidor. SCD Tipo 2.';

/*
Dimensión de Clientes — Inventario Histórico (dim_clientes_inventario)
  SCD Tipo 2 puro. Cada snapshot del total de clientes servidos queda registrado
  con un rango de vigencia [fecha_inicio, fecha_fin). Esto resuelve el problema
  del "denominador dinámico" para SAIDI/SAIFI: cuando se calcula el indicador
  para una fecha histórica, la vista analítica hace JOIN con la fila del
  inventario que estaba activa en ese momento exacto.

  Ejemplo:
    - 2024-01-01: 10,000 clientes → fila A (activo)
    - 2024-06-15: 12,500 clientes → fila A cerrada (fecha_fin = 2024-06-15),
                  fila B abierta (fecha_inicio = 2024-06-15)
    Un SAIDI del 2024-03-10 usará 10,000; uno del 2024-08-20 usará 12,500.
*/
CREATE TABLE dim_clientes_inventario (
    sk_clientes           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    total_clientes_servidos INTEGER     NOT NULL,
    fecha_inicio          TIMESTAMPTZ   NOT NULL,
    fecha_fin             TIMESTAMPTZ,
    activo_bool           BOOLEAN       NOT NULL DEFAULT TRUE,
    version               INTEGER       NOT NULL DEFAULT 1,
    fecha_actualizacion   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_fechas_scd2 CHECK (fecha_fin IS NULL OR fecha_fin > fecha_inicio)
);

COMMENT ON TABLE dim_clientes_inventario IS
'SCD Tipo 2: inventario histórico de clientes. Denominador dinámico para SAIDI/SAIFI.';


-- ====================== TABLA DE HECHOS ====================================

/*
Tabla de Hechos: fact_interrupciones
  Grano: un evento de interrupción consolidado por medidor (par OUTAGE→RESTORATION).
  Métricas: duracion_minutos (aditiva), clientes_afectados (semi-aditiva).
  Claves sustitutas: referencian las SK de las dimensiones vigentes al momento
  de la interrupción (no la versión actual). Esto es crítico: si un medidor
  cambió de transformador después de una falla, la interrupción debe reportarse
  bajo la topología histórica, no la actual.

  id_lote_procesamiento: trazabilidad. Permite auditoría inversa: dado un lote,
  encontrar todos los hechos generados y, si es necesario, anularlos sin afectar
  otros lotes (idempotencia a nivel de batch).
*/
CREATE TABLE fact_interrupciones (
    sk_interrupcion        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sk_tiempo              BIGINT        NOT NULL,
    sk_red_electrica       BIGINT        NOT NULL,
    sk_geografia_urbana    BIGINT        NOT NULL,
    sk_clientes            BIGINT        NOT NULL,
    id_medidor             BIGINT        NOT NULL,
    timestamp_inicio       TIMESTAMPTZ   NOT NULL,
    timestamp_fin          TIMESTAMPTZ,
    duracion_minutos       NUMERIC(10,2),
    clientes_afectados     INTEGER       NOT NULL DEFAULT 1
        CHECK (clientes_afectados >= 1),
    id_lote_procesamiento  INTEGER,
    excluido_med           BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_procesamiento    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    -- Restricciones de integridad referencial
    CONSTRAINT fk_fact_tiempo
        FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    CONSTRAINT fk_fact_red_electrica
        FOREIGN KEY (sk_red_electrica) REFERENCES dim_red_electrica(sk_red_electrica),
    CONSTRAINT fk_fact_geografia
        FOREIGN KEY (sk_geografia_urbana) REFERENCES dim_geografia_urbana(sk_geografia_urbana),
    CONSTRAINT fk_fact_clientes
        FOREIGN KEY (sk_clientes) REFERENCES dim_clientes_inventario(sk_clientes),

    -- Regla de negocio: timestamp_fin debe ser posterior a timestamp_inicio
    CONSTRAINT chk_fechas_interrupcion
        CHECK (timestamp_fin IS NULL OR timestamp_fin > timestamp_inicio)
);

COMMENT ON TABLE fact_interrupciones IS
'Hechos atómicos de interrupciones. Grano: un evento OUTAGE→RESTORATION por medidor.';


-- ===========================================================================
-- ESTRATEGIA DE INDEXACIÓN BRIN (Block Range Index)
-- ===========================================================================

/*
Justificación de BRIN sobre B-Tree para la tabla de hechos:

  1. Correlación física: el ELT procesa eventos en orden cronológico, y
     PostgreSQL inserta las filas secuencialmente. El timestamp_inicio de las
     filas contiguas está dentro del mismo bloque o bloques adyacentes.
     BRIN explota esta correlación: almacena solo el valor mínimo y máximo
     por cada rango de bloques (por defecto 128 páginas = 1 MB).

  2. Tamaño: un índice B-Tree sobre 10 millones de filas con TIMESTAMPTZ ocupa
     ~250-400 MB. Un índice BRIN equivalente ocupa ~50-100 KB. Esto es 3-4
     órdenes de magnitud menos. En Supabase (con almacenamiento facturado),
     esta diferencia es costo real.

  3. Rendimiento de escaneo: para consultas de tipo "dame todas las
     interrupciones entre enero y marzo 2025", BRIN descarta bloques completos
     cuyos rangos no solapan con el filtro. El planificador salta físicamente
     porciones enteras de la tabla sin leerlas. Un B-Tree también lo hace,
     pero a costa de mantener millones de entradas ordenadas.

  4. pages_per_range = 32: reduce el rango de cada entrada BRIN a 32 páginas
     en lugar de 128. Esto mejora la precisión del filtro (menos falsos
     positivos) a cambio de un índice ligeramente más grande (~200 KB).
     Para una tabla de hechos con inserción cronológica estricta, este es
     el punto óptimo entre tamaño y selectividad.

  5. Índice único compuesto (sk_tiempo, sk_interrupcion): existe UN solo
     B-Tree sobre la surrogate key de tiempo. Esto cubre el caso de JOIN
     con dim_tiempo que Power BI genera cuando el usuario filtra por mes/año.
     No se indexan las demás surrogate keys individualmente porque Power BI
     filtra primero por tiempo en el 90 % de los dashboards.
*/
CREATE INDEX IF NOT EXISTS idx_brin_fact_timestamp_inicio
    ON fact_interrupciones USING BRIN (timestamp_inicio)
    WITH (pages_per_range = 32);

CREATE INDEX IF NOT EXISTS idx_brin_fact_timestamp_fin
    ON fact_interrupciones USING BRIN (timestamp_fin)
    WITH (pages_per_range = 32);

-- B-Tree auxiliar para JOINs frecuentes con dim_tiempo (único índice B-Tree pesado)
CREATE INDEX IF NOT EXISTS idx_fact_sk_tiempo
    ON fact_interrupciones (sk_tiempo);

-- Índice parcial para filtros de exclusión MED en vistas analíticas
CREATE INDEX IF NOT EXISTS idx_fact_no_med
    ON fact_interrupciones (timestamp_inicio)
    WHERE excluido_med = FALSE;


-- ===========================================================================
-- TABLA DE AUDITORÍA: err_telemetria
-- ===========================================================================

/*
Tabla de cuarentena para eventos anómalos.
  Se desvían aquí:
    - POWER_RESTORATION sin POWER_OUTAGE previa (restauración huérfana).
    - POWER_OUTAGE sin POWER_RESTORATION dentro del lote y fuera de la ventana
      de espera configurable (outage abierto no resuelto).
    - Eventos con timestamp futuro o con más de N horas de diferencia respecto
      al timestamp de carga (posible corrupción de reloj del medidor).

  El stored procedure no aborta ante estos eventos: los aísla y continúa con
  el resto del lote. Esto sigue el principio de "fail-safe" en pipelines de
  datos: datos sucios no deben bloquear datos limpios.
*/
CREATE TABLE err_telemetria (
    id_error           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_evento_origen   BIGINT,
    id_medidor         BIGINT,
    timestamp_evento   TIMESTAMPTZ,
    tipo_evento        VARCHAR(20),
    motivo_error       VARCHAR(200)  NOT NULL,
    detalle_tecnico    TEXT,
    id_lote_procesamiento INTEGER,
    fecha_deteccion    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    resuelto           BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_resolucion   TIMESTAMPTZ
);

COMMENT ON TABLE err_telemetria IS
'Registro de cuarentena para eventos huérfanos, fuera de orden o corruptos.';


-- ===========================================================================
-- SECUENCIA AUXILIAR: identificación de lotes de procesamiento
-- ===========================================================================

CREATE SEQUENCE IF NOT EXISTS seq_lote_procesamiento
    START WITH 1
    INCREMENT BY 1
    NO CYCLE;

COMMENT ON SEQUENCE seq_lote_procesamiento IS
'Identificador único por ejecución del stored procedure de reconciliación.';


-- ===========================================================================
-- TABLA DE CONTROL: metadatos de lotes procesados
-- ===========================================================================

CREATE TABLE ctrl_lotes_procesamiento (
    id_lote        INTEGER PRIMARY KEY DEFAULT nextval('seq_lote_procesamiento'),
    fecha_inicio   TIMESTAMPTZ   NOT NULL,
    fecha_fin      TIMESTAMPTZ   NOT NULL,
    total_eventos  INTEGER       NOT NULL DEFAULT 0,
    total_hechos   INTEGER       NOT NULL DEFAULT 0,
    total_huerfanos INTEGER      NOT NULL DEFAULT 0,
    total_transitorios INTEGER   NOT NULL DEFAULT 0,
    estado         VARCHAR(20)   NOT NULL DEFAULT 'INICIADO'
        CHECK (estado IN ('INICIADO', 'COMPLETADO', 'FALLIDO', 'REVERTIDO')),
    fecha_ejecucion TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    duracion_segundos NUMERIC(10,2)
);

COMMENT ON TABLE ctrl_lotes_procesamiento IS
'Metadata de cada lote ejecutado. Trazabilidad y soporte de reversión.';


-- ===========================================================================
-- CARGA INICIAL DE dim_tiempo (ejecutar UNA sola vez)
-- ===========================================================================

/*
Precarga la dimensión de tiempo desde 2020-01-01 hasta 2030-12-31 a
granularidad de minuto. Esto genera ~5.7 millones de filas.

En PostgreSQL 15+, generate_series con intervalos produce un plan de
ejecución lineal eficiente. La carga completa demora ~20-40 segundos
dependiendo del tier de Supabase.

Nota: si el proyecto tiene restricciones de storage, se puede reducir el
rango o cargar on-demand desde la tabla de hechos. Pero para un data mart
académico con un solo proyecto, la precarga es la opción más simple y
elimina la necesidad de lógica de upsert en el SP de reconciliación.
*/
INSERT INTO dim_tiempo (
    timestamp_completo, minuto, hora, dia, dia_semana, dia_semana_num,
    semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana
)
SELECT
    ts                                                    AS timestamp_completo,
    EXTRACT(MINUTE FROM ts)::SMALLINT                     AS minuto,
    EXTRACT(HOUR   FROM ts)::SMALLINT                     AS hora,
    EXTRACT(DAY    FROM ts)::SMALLINT                     AS dia,
    TRIM(TO_CHAR(ts, 'Day'))                              AS dia_semana,
    EXTRACT(ISODOW FROM ts)::SMALLINT                     AS dia_semana_num,
    EXTRACT(WEEK   FROM ts)::SMALLINT                     AS semana_anio,
    EXTRACT(MONTH  FROM ts)::SMALLINT                     AS mes,
    TRIM(TO_CHAR(ts, 'Month'))                            AS nombre_mes,
    EXTRACT(QUARTER FROM ts)::SMALLINT                    AS trimestre,
    EXTRACT(YEAR   FROM ts)::SMALLINT                     AS anio,
    EXTRACT(ISODOW FROM ts) IN (6, 7)                     AS es_fin_semana
FROM generate_series(
    '2020-01-01 00:00:00+00'::TIMESTAMPTZ,
    '2030-12-31 23:59:00+00'::TIMESTAMPTZ,
    '1 minute'::INTERVAL
) AS ts
ON CONFLICT (timestamp_completo) DO NOTHING;
