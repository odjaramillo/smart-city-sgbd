-- Active: 1779816248964@@192.168.1.48@5432@ucab_project
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
--   - dim_tiempo a nivel de día (3,650 filas vs 5.7M en granularidad minuto).
--     Los hechos almacenan timestamps crudos para cálculos de duración. La
--     dimensión solo provee jerarquía de drill-down (año/trimestre/mes/día).
--     Decisión: almacenamiento 1000x menor, jerarquía suficiente para IEEE 1366.
--   - dim_clientes_inventario SCD Tipo 2 para denominador dinámico SAIDI/SAIFI.
--     Cada snapshot de clientes servidos tiene rango [fecha_inicio, fecha_fin).
--   - dim_red_electrica SCD Tipo 2: la clave única es (id_medidor_origen,
--     fecha_inicio) para garantizar un solo registro activo por medidor por
--     período. Evita duplicados de SCD2 que romperían facts.
--   - Índices BRIN sobre timestamps en facts: correlación física alta porque
--     ELT inserta cronológicamente. Tamaño ~100KB vs ~400MB de B-tree.
--   - Índices B-tree sobre FKs de hechos para JOINs eficientes con dimensiones.
-- ==============================================================================

-- --------------------------------------------------------------------------
-- LIMPIEZA IDEMPOTENTE: eliminar objetos existentes antes de recrear
-- --------------------------------------------------------------------------

DROP TABLE IF EXISTS fact_interrupciones CASCADE;
DROP TABLE IF EXISTS dim_clientes_inventario CASCADE;
DROP TABLE IF EXISTS dim_red_electrica CASCADE;
DROP TABLE IF EXISTS dim_geografia_urbana CASCADE;
DROP TABLE IF EXISTS dim_tiempo CASCADE;
DROP TABLE IF EXISTS staging_eventos CASCADE;
DROP TABLE IF EXISTS err_telemetria CASCADE;
DROP TABLE IF EXISTS ctrl_lotes_procesamiento CASCADE;
DROP SEQUENCE IF EXISTS seq_lote_procesamiento CASCADE;

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
CREATE TABLE staging_eventos (
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
CREATE INDEX idx_staging_procesado_medidor_ts
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
  Granularidad: 1 día. Decisión de arquitectura (design.md):
  - Almacena 3,650 filas (10 años) vs 5.7M (minuto a minuto)
  - Los hechos guardan timestamps crudos para duración INTERVAL
  - dim_tiempo solo provee jerarquía: año → trimestre → mes → día
  - Suficiente para IEEE 1366 (cálculos en minutos, no en la dimensión)

  Estrategia de carga: se precarga masivamente con generate_series.
  No se actualiza incrementalmente porque el rango de fechas es acotado.
*/
CREATE TABLE dim_tiempo (
    sk_tiempo          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    timestamp_completo DATE        NOT NULL UNIQUE,
    dia                SMALLINT    NOT NULL CHECK (dia BETWEEN 1 AND 31),
    dia_semana         VARCHAR(10) NOT NULL,
    dia_semana_num     SMALLINT    NOT NULL CHECK (dia_semana_num BETWEEN 1 AND 7),
    semana_anio        SMALLINT    NOT NULL CHECK (semana_anio BETWEEN 1 AND 53),
    mes                SMALLINT    NOT NULL CHECK (mes BETWEEN 1 AND 12),
    nombre_mes         VARCHAR(15) NOT NULL,
    trimestre          SMALLINT    NOT NULL CHECK (trimestre BETWEEN 1 AND 4),
    anio               SMALLINT    NOT NULL,
    es_fin_semana      BOOLEAN     NOT NULL,
    es_feriado         BOOLEAN     NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE dim_tiempo IS
'Dimensión temporal a granularidad de día. Jerarquía: Año → Trimestre → Mes → Día.';

/*
Índice en timestamp_completo para JOINs eficientes con la fact table.
DATE es suficiente para filtrado por día.
*/
CREATE INDEX idx_dim_tiempo_timestamp ON dim_tiempo (timestamp_completo);


/*
Dimensión Geografía Urbana (dim_geografia_urbana)
  Desnormalizada intencionalmente: sector, distrito y coordenadas viven en una
  sola tabla. Evita JOINs adicionales en el modelo estrella.

  Constraint UNIQUE(sector_urbano): specs requieren mapeo 1:N determinístico
  sin LIMIT 1 ni fallbacks. Cada sector tiene una sola fila en la dimensión.
*/
CREATE TABLE dim_geografia_urbana (
    sk_geografia_urbana BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sector_urbano       VARCHAR(100) NOT NULL UNIQUE,
    distrito            VARCHAR(100) NOT NULL,
    latitud            NUMERIC(9,6),
    longitud           NUMERIC(9,6),
    nivel_criticidad   VARCHAR(20)  NOT NULL DEFAULT 'NORMAL'
        CHECK (nivel_criticidad IN ('CRITICO', 'ALTO', 'MEDIO', 'NORMAL', 'BAJO')),
    fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE dim_geografia_urbana IS
'Dimensión geográfica desnormalizada. UNIQUE(sector_urbano) para mapeo 1:N determinístico.';


/*
Dimensión Red Eléctrica (dim_red_electrica)
  Jerarquía explícita: Subestación → Circuito → Transformador → Medidor.
  Cada nivel como columna independiente (no self-referencing FK) para
  evitar JOINs recursivos en Power BI.

  SCD Tipo 2: la constraint UNIQUE(id_medidor_origen, fecha_inicio) garantiza
  que no haya duplicados de historial por medidor. Solo un registro activo
  (fecha_fin IS NULL) por medidor en cualquier momento.
*/
CREATE TABLE dim_red_electrica (
    sk_red_electrica   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_medidor         BIGINT        NOT NULL,
    id_medidor_origen  BIGINT        NOT NULL,
    codigo_medidor     VARCHAR(50)   NOT NULL,
    transformador      VARCHAR(100) NOT NULL,
    circuito           VARCHAR(100) NOT NULL,
    subestacion        VARCHAR(100) NOT NULL,
    capacidad_kva      NUMERIC(10,2),
    estado_operativo   VARCHAR(30)   NOT NULL DEFAULT 'ACTIVO',
    fecha_inicio       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    fecha_fin          TIMESTAMPTZ,
    activo_bool        BOOLEAN       NOT NULL DEFAULT TRUE,

    -- SCD2 uniqueness: un solo registro activo por medidor por período
    CONSTRAINT uq_medidor_scd2 UNIQUE (id_medidor_origen, fecha_inicio)
);

COMMENT ON TABLE dim_red_electrica IS
'Jerarquía de red: Sub → Circuito → Transformador → Medidor. SCD Tipo 2 con UNIQUE(id_medidor_origen, fecha_inicio).';

/*
Índice en id_medidor para búsquedas frecuentes por medidor en ELT.
Índice en activo_bool para filtrar solo registros vigentes.
*/
CREATE INDEX idx_dim_red_medidor ON dim_red_electrica (id_medidor);
CREATE INDEX idx_dim_red_activo ON dim_red_electrica (activo_bool) WHERE activo_bool = TRUE;


/*
Dimensión de Clientes — Inventario Histórico (dim_clientes_inventario)
  SCD Tipo 2 puro. Cada snapshot del total de clientes servidos queda registrado
  con rango [fecha_inicio, fecha_fin).

  CHECK constraints:
  - total_clientes_servidos > 0: SAIDI/SAIFI requieren denominador positivo
  - fecha_fin > fecha_inicio: rango válido para SCD2
*/
CREATE TABLE dim_clientes_inventario (
    sk_clientes           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    total_clientes_servidos INTEGER     NOT NULL
        CHECK (total_clientes_servidos > 0),
    fecha_inicio          TIMESTAMPTZ   NOT NULL,
    fecha_fin             TIMESTAMPTZ,
    activo_bool           BOOLEAN       NOT NULL DEFAULT TRUE,
    version               INTEGER       NOT NULL DEFAULT 1,
    fecha_actualizacion   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_fechas_scd2 CHECK (fecha_fin IS NULL OR fecha_fin > fecha_inicio)
);

COMMENT ON TABLE dim_clientes_inventario IS
'SCD Tipo 2: inventario histórico de clientes. Denominador dinámico para SAIDI/SAIFI. CHECK total_clientes_servidos > 0.';

/*
Índice en activo_bool para filtrado rápido del registro vigente.
Índice en fecha_inicio para búsquedas por período.
*/
CREATE INDEX idx_dim_clientes_activo ON dim_clientes_inventario (activo_bool) WHERE activo_bool = TRUE;
CREATE INDEX idx_dim_clientes_fecha ON dim_clientes_inventario (fecha_inicio);


-- ====================== TABLA DE HECHOS ====================================

/*
Tabla de Hechos: fact_interrupciones
  Grano: un evento de interrupción consolidado por medidor (par OUTAGE→RESTORATION).
  Métricas: duracion_minutos (aditiva), clientes_afectados (semi-aditiva).

  Constraint UNIQUE(id_medidor, timestamp_inicio): evita hechos duplicados.
  Si el ELT se ejecuta dos veces con los mismos eventos, el segundo INSERT
  falla por integridad, protegiendo la idempotencia.

  Claves sustitutas referencian SKs vigentes al momento de la interrupción
  (no la versión actual). Crítico: si un medidor cambió de transformador
  después de una falla, la interrupción se reporta bajo la topología histórica.

  Índices:
  - BRIN en timestamp_inicio/fin: correlación física alta, tamaño mínimo
  - B-tree en sk_tiempo: JOIN frecuente con dim_tiempo
  - B-tree en sk_red_electrica, sk_geografia_urbana, sk_clientes: FK JOINs
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

    -- Uniqueness: un hecho por medidor por timestamp_inicio
    CONSTRAINT uq_fact_medidor_inicio UNIQUE (id_medidor, timestamp_inicio),

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
'Hechos atómicos de interrupciones. UNIQUE(id_medidor, timestamp_inicio) previene duplicados. Grano: OUTAGE→RESTORATION por medidor.';

-- Índices para JOIN performance (FK lookups)
CREATE INDEX idx_fact_sk_tiempo ON fact_interrupciones (sk_tiempo);
CREATE INDEX idx_fact_sk_red_electrica ON fact_interrupciones (sk_red_electrica);
CREATE INDEX idx_fact_sk_geografia_urbana ON fact_interrupciones (sk_geografia_urbana);
CREATE INDEX idx_fact_sk_clientes ON fact_interrupciones (sk_clientes);

-- BRIN para filtrado temporal (correlación física con insertions cronológicas)
CREATE INDEX idx_brin_fact_timestamp_inicio
    ON fact_interrupciones USING BRIN (timestamp_inicio)
    WITH (pages_per_range = 32);

CREATE INDEX idx_brin_fact_timestamp_fin
    ON fact_interrupciones USING BRIN (timestamp_fin)
    WITH (pages_per_range = 32);

-- Índice parcial para filtros de exclusión MED en vistas analíticas
CREATE INDEX idx_fact_no_med
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

CREATE SEQUENCE seq_lote_procesamiento
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
-- Granularidad: 1 día | Rango: 2020-01-01 a 2029-12-31 (10 años = 3,650 días)
-- ===========================================================================

/*
Precarga la dimensión de tiempo desde 2020-01-01 hasta 2029-12-31.
Genera ~3,650 filas (vs 5.7M en granularidad minuto).

En PostgreSQL 15+, generate_series con intervalos de día produce un plan
de ejecución lineal eficiente. La carga completa demora < 1 segundo.

La fecha fin es 2029-12-31 (no 2030) para mantener exactamente 10 años
y 3,650 filas (aproximado, tergantung de años bisiestos).
*/
INSERT INTO dim_tiempo (
    timestamp_completo, dia, dia_semana, dia_semana_num,
    semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana
)
SELECT
    ts                                                    AS timestamp_completo,
    EXTRACT(DAY    FROM ts)::SMALLINT                     AS dia,
    TRIM(TO_CHAR(ts, 'Day'))                              AS dia_semana,
    EXTRACT(ISODOW FROM ts)::SMALLINT                     AS dia_semana_num,
    EXTRACT(WEEK   FROM ts)::SMALLINT                      AS semana_anio,
    EXTRACT(MONTH  FROM ts)::SMALLINT                      AS mes,
    TRIM(TO_CHAR(ts, 'Month'))                            AS nombre_mes,
    EXTRACT(QUARTER FROM ts)::SMALLINT                     AS trimestre,
    EXTRACT(YEAR   FROM ts)::SMALLINT                      AS anio,
    EXTRACT(ISODOW FROM ts) IN (6, 7)                     AS es_fin_semana
FROM generate_series(
    '2020-01-01'::DATE,
    '2029-12-31'::DATE,
    '1 day'::INTERVAL
) AS ts
ON CONFLICT (timestamp_completo) DO NOTHING;