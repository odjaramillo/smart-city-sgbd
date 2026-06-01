-- Active: 1779816248964@@192.168.1.48@5432@ucab_project
-- ==============================================================================
-- PROYECTO: Arquitectura Analitica de Resiliencia para Smart City (Smart Grid)
-- MATERIA:  Gestion de Datos -- Prof. Armen Djenanian
-- FASE 1:   Modelado Dimensional (Kimball) + Estrategia de Indexacion
-- PLATAFORMA: Supabase (PostgreSQL 15+)
-- ==============================================================================
-- --------------------------------------------------------------------------
-- ESQUEMA: staging (capa de aterrizaje crudo -- poblada por n8n)
-- --------------------------------------------------------------------------
/*
Staging Eventos: CHECK expandido para incluir POWER_OUTAGE, POWER_RESTORATION,
VOLTAGE_SPIKE, VOLTAGE_SAG, HEARTBEAT, UNKNOWN. Alineado con dim_tipo_evento.
*/
CREATE TABLE IF NOT EXISTS staging_eventos (
    id_evento        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_medidor       BIGINT        NOT NULL,
    timestamp_evento TIMESTAMPTZ   NOT NULL,
    tipo_evento      VARCHAR(50)   NOT NULL
        CHECK (tipo_evento IN (
            'POWER_OUTAGE', 'POWER_RESTORATION',
            'VOLTAGE_SPIKE', 'VOLTAGE_SAG',
            'HEARTBEAT', 'UNKNOWN'
        )),
    procesado        BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_carga      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_staging_procesado_medidor_ts
    ON staging_eventos (procesado, id_medidor, timestamp_evento)
    WHERE procesado = FALSE;
COMMENT ON TABLE staging_eventos IS
'Telemetria cruda de interrupciones desde n8n. Punto de entrada del pipeline ELT.';
/*
Staging Telemetria: Landing zone para lecturas horarias de consumo/voltaje.
Almacena consumo en Wh (raw); la conversion a kWh ocurre en el SP.
*/
CREATE TABLE staging_telemetria (
    id_staging           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_medidor           BIGINT        NOT NULL,
    timestamp_lectura    TIMESTAMPTZ   NOT NULL,
    consumo_wh           NUMERIC(12,2) NOT NULL CHECK (consumo_wh >= 0),
    voltaje              NUMERIC(8,2)  NOT NULL CHECK (voltaje >= 0 AND voltaje <= 1000),
    tipo_lectura         VARCHAR(30)   NOT NULL DEFAULT 'LECTURA_PERIODICA'
        CHECK (tipo_lectura IN ('LECTURA_PERIODICA', 'LECTURA_EVENTO', 'HEARTBEAT')),
    procesado            BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_carga          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    id_lote_procesamiento BIGINT
);
CREATE INDEX idx_staging_telemetria_procesado
    ON staging_telemetria (procesado, id_medidor, timestamp_lectura)
    WHERE procesado = FALSE;
COMMENT ON TABLE staging_telemetria IS
'Landing zone para lecturas periodicas de consumo/voltaje.';
-- --------------------------------------------------------------------------
-- ESQUEMA: dwh (Data Warehouse -- Modelo en Estrella / Constelacion)
-- --------------------------------------------------------------------------
-- ========================== DIMENSIONES ====================================

-- ===========================================================================
-- dim_fecha: granularidad DIARIA — para agregaciones SAIDI/SAIFI, tendencias
-- y cualquier análisis a nivel de día, mes, trimestre, año.
-- Reemplaza el rol temporal de dim_tiempo en las fact tables analíticas.
-- ===========================================================================
CREATE TABLE dim_fecha (
    sk_fecha           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha              DATE          NOT NULL UNIQUE,
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
COMMENT ON TABLE dim_fecha IS
'Dimension de fecha (granularidad diaria). Jerarquia: Anio -> Trimestre -> Mes -> Dia.';

-- ===========================================================================
-- dim_tiempo: granularidad HORARIA — para el heatmap hora x dia_semana
-- y patrones de distribucion intra-dia. Solo 24 filas (horas 0-23).
-- ===========================================================================
CREATE TABLE dim_tiempo (
    sk_tiempo          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hora               SMALLINT      NOT NULL UNIQUE CHECK (hora BETWEEN 0 AND 23),
    franja_horaria     VARCHAR(20)   NOT NULL
        CHECK (franja_horaria IN ('Madrugada', 'Manana', 'Tarde', 'Pico', 'Noche'))
);
COMMENT ON TABLE dim_tiempo IS
'Dimension de hora del dia (24 filas). Para heatmap y patrones intra-dia.';

CREATE TABLE dim_geografia_urbana (
    sk_geografia_urbana BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sector_urbano     VARCHAR(100)  NOT NULL,
    distrito          VARCHAR(100)  NOT NULL,
    latitud           NUMERIC(9,6),
    longitud          NUMERIC(9,6),
    nivel_criticidad  VARCHAR(20)   NOT NULL DEFAULT 'NORMAL'
        CHECK (nivel_criticidad IN ('CRITICO', 'ALTO', 'MEDIO', 'NORMAL', 'BAJO')),
    fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE dim_red_electrica (
    sk_red_electrica   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_medidor         BIGINT        NOT NULL,
    id_medidor_origen  BIGINT        NOT NULL,
    codigo_medidor     VARCHAR(50)   NOT NULL,
    transformador      VARCHAR(100)  NOT NULL,
    circuito           VARCHAR(100)  NOT NULL,
    subestacion        VARCHAR(100)  NOT NULL,
    -- Fix H-4: la geografia es un atributo del activo de red (ubicacion del medidor).
    -- Nullable a nivel DDL porque el seed la asigna por UPDATE y el ELT siempre la resuelve.
    sk_geografia_urbana BIGINT       REFERENCES dim_geografia_urbana(sk_geografia_urbana),
    capacidad_kva      NUMERIC(10,2),
    estado_operativo   VARCHAR(30)   NOT NULL DEFAULT 'ACTIVO',
    fecha_inicio       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    fecha_fin          TIMESTAMPTZ,
    activo_bool        BOOLEAN       NOT NULL DEFAULT TRUE,
    fecha_actualizacion TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
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
/*
Dim Tipo Evento (Stress Test Catalog):
La fila con sk_tipo_evento = -1 es obligatoria y se inserta en 04-datos-semilla.sql.
*/
CREATE TABLE dim_tipo_evento (
    sk_tipo_evento        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_evento         VARCHAR(50)  NOT NULL UNIQUE,
    categoria             VARCHAR(30)  NOT NULL,
    severidad             VARCHAR(20)  NOT NULL
        CHECK (severidad IN ('BAJA', 'MEDIA', 'ALTA', 'CRITICA', 'DESCONOCIDA')),
    es_critico            BOOLEAN      NOT NULL DEFAULT FALSE,
    descripcion           TEXT,
    regla_vigencia_desde  TIMESTAMPTZ,
    regla_vigencia_hasta  TIMESTAMPTZ
);
CREATE INDEX idx_dim_tipo_evento_categoria ON dim_tipo_evento (categoria);
CREATE INDEX idx_dim_tipo_evento_codigo ON dim_tipo_evento (codigo_evento);
-- Fix H-4: indice para el JOIN red -> geografia
CREATE INDEX idx_dim_red_geografia ON dim_red_electrica (sk_geografia_urbana);
-- ===========================================================================
-- SECUENCIA Y TABLA DE CONTROL DE LOTES
-- Se definen ANTES de las tablas de hechos porque fact_telemetria mantiene una
-- FK hacia ctrl_lotes_procesamiento(id_lote). (Fix H-1: referencia adelantada)
-- ===========================================================================
CREATE SEQUENCE IF NOT EXISTS seq_lote_procesamiento
    START WITH 1
    INCREMENT BY 1
    NO CYCLE;
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
-- ====================== TABLAS DE HECHOS ====================================
/*
Fact Interrupciones: sk_fecha para analisis temporal diario/mensual,
sk_tiempo para patron horario (heatmap). Ambas FKs obligatorias.
*/
CREATE TABLE fact_interrupciones (
    sk_interrupcion        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sk_fecha               BIGINT        NOT NULL,
    sk_tiempo              BIGINT        NOT NULL,
    sk_red_electrica       BIGINT        NOT NULL,
    sk_geografia_urbana    BIGINT        NOT NULL,
    sk_clientes            BIGINT        NOT NULL,
    sk_tipo_evento         BIGINT        NOT NULL DEFAULT -1
        REFERENCES dim_tipo_evento(sk_tipo_evento) ON DELETE SET DEFAULT,
    id_medidor             BIGINT        NOT NULL,
    timestamp_inicio       TIMESTAMPTZ   NOT NULL,
    timestamp_fin          TIMESTAMPTZ,
    duracion_minutos       NUMERIC(10,2),
    clientes_afectados     INTEGER       NOT NULL DEFAULT 1
        CHECK (clientes_afectados >= 1),
    id_lote_procesamiento  INTEGER,
    excluido_med           BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_procesamiento    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_fact_fecha
        FOREIGN KEY (sk_fecha) REFERENCES dim_fecha(sk_fecha),
    CONSTRAINT fk_fact_tiempo
        FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    CONSTRAINT fk_fact_red_electrica
        FOREIGN KEY (sk_red_electrica) REFERENCES dim_red_electrica(sk_red_electrica),
    CONSTRAINT fk_fact_geografia
        FOREIGN KEY (sk_geografia_urbana) REFERENCES dim_geografia_urbana(sk_geografia_urbana),
    CONSTRAINT fk_fact_clientes
        FOREIGN KEY (sk_clientes) REFERENCES dim_clientes_inventario(sk_clientes),
    CONSTRAINT chk_fechas_interrupcion
        CHECK (timestamp_fin IS NULL OR timestamp_fin > timestamp_inicio)
);
/*
Fact Telemetria: lectura periodica de consumo/voltaje por medidor, granularidad horaria.
Unique: una lectura por medidor por hora.
*/
CREATE TABLE fact_telemetria (
    sk_telemetria          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sk_fecha               BIGINT        NOT NULL REFERENCES dim_fecha(sk_fecha),
    sk_tiempo              BIGINT        NOT NULL REFERENCES dim_tiempo(sk_tiempo),
    sk_red_electrica       BIGINT        NOT NULL REFERENCES dim_red_electrica(sk_red_electrica),
    sk_geografia_urbana    BIGINT        NOT NULL REFERENCES dim_geografia_urbana(sk_geografia_urbana),
    sk_tipo_evento         BIGINT        NOT NULL DEFAULT -1
        REFERENCES dim_tipo_evento(sk_tipo_evento) ON DELETE SET DEFAULT,
    timestamp_lectura      TIMESTAMPTZ   NOT NULL,
    consumo_kwh           NUMERIC(12,4) NOT NULL CHECK (consumo_kwh >= 0),
    voltaje                NUMERIC(8,2)  NOT NULL CHECK (voltaje >= 0 AND voltaje <= 1000),
    id_lote_procesamiento  BIGINT        REFERENCES ctrl_lotes_procesamiento(id_lote)
);
-- BRIN para consultas analiticas por rango temporal
CREATE INDEX idx_fact_telemetria_brin_timestamp
    ON fact_telemetria USING BRIN (timestamp_lectura)
    WITH (pages_per_range = 32);
-- B-Tree para JOINs
CREATE INDEX idx_fact_telemetria_sk_fecha  ON fact_telemetria (sk_fecha);
CREATE INDEX idx_fact_telemetria_sk_tiempo ON fact_telemetria (sk_tiempo);
CREATE INDEX idx_fact_telemetria_sk_red    ON fact_telemetria (sk_red_electrica);
CREATE INDEX idx_fact_telemetria_sk_tipo   ON fact_telemetria (sk_tipo_evento);
-- Unique: una lectura por medidor por hora (usando sk_fecha + sk_tiempo)
CREATE UNIQUE INDEX uq_fact_telemetria_medidor_hora
    ON fact_telemetria (sk_red_electrica, sk_fecha, sk_tiempo);
-- ===========================================================================
-- ESTRATEGIA DE INDEXACION BRIN
-- ===========================================================================
CREATE INDEX IF NOT EXISTS idx_brin_fact_timestamp_inicio
    ON fact_interrupciones USING BRIN (timestamp_inicio)
    WITH (pages_per_range = 32);
CREATE INDEX IF NOT EXISTS idx_brin_fact_timestamp_fin
    ON fact_interrupciones USING BRIN (timestamp_fin)
    WITH (pages_per_range = 32);
CREATE INDEX IF NOT EXISTS idx_fact_sk_fecha
    ON fact_interrupciones (sk_fecha);
CREATE INDEX IF NOT EXISTS idx_fact_sk_tiempo
    ON fact_interrupciones (sk_tiempo);
CREATE INDEX IF NOT EXISTS idx_fact_no_med
    ON fact_interrupciones (timestamp_inicio)
    WHERE excluido_med = FALSE;
CREATE INDEX idx_fact_interrupciones_tipo
    ON fact_interrupciones (sk_tipo_evento);
-- ===========================================================================
-- TABLA DE AUDITORIA: err_telemetria
-- ===========================================================================
/*
tipo_error: discriminador que separa errores de interrupciones de errores de telemetria.
*/
CREATE TABLE err_telemetria (
    id_error           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_evento_origen   BIGINT,
    id_medidor         BIGINT,
    timestamp_evento   TIMESTAMPTZ,
    tipo_evento        VARCHAR(20),
    tipo_error         VARCHAR(50)   NOT NULL DEFAULT 'INTERRUPCION'
        CHECK (tipo_error IN (
            'INTERRUPCION', 'RESTAURACION_HUERFANA', 'CORTE_HUERFANO',
            'TELEMETRIA', 'VOLTAGE_OUT_OF_RANGE', 'CONSUMO_NEGATIVO',
            'EVENTO_DESCONOCIDO', 'MEDIDOR_INACTIVO', 'DUPLICADO'
        )),
    motivo_error       VARCHAR(200)  NOT NULL,
    detalle_tecnico    TEXT,
    id_lote_procesamiento INTEGER,
    fecha_deteccion    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    resuelto           BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_resolucion   TIMESTAMPTZ
);
CREATE INDEX idx_err_telemetria_tipo ON err_telemetria (tipo_error);

-- ===========================================================================
-- CARGA INICIAL DE dim_fecha (ejecutar UNA sola vez)
-- Granularidad diaria: 2024-01-01 a 2026-12-31 = ~1,096 filas
-- ===========================================================================
INSERT INTO dim_fecha (
    fecha, dia, dia_semana, dia_semana_num, semana_anio,
    mes, nombre_mes, trimestre, anio, es_fin_semana
)
SELECT
    d::DATE                                               AS fecha,
    EXTRACT(DAY    FROM d)::SMALLINT                      AS dia,
    TRIM(TO_CHAR(d, 'Day'))                               AS dia_semana,
    EXTRACT(ISODOW FROM d)::SMALLINT                      AS dia_semana_num,
    EXTRACT(WEEK   FROM d)::SMALLINT                      AS semana_anio,
    EXTRACT(MONTH  FROM d)::SMALLINT                      AS mes,
    TRIM(TO_CHAR(d, 'Month'))                             AS nombre_mes,
    EXTRACT(QUARTER FROM d)::SMALLINT                     AS trimestre,
    EXTRACT(YEAR   FROM d)::SMALLINT                      AS anio,
    EXTRACT(ISODOW FROM d) IN (6, 7)                      AS es_fin_semana
FROM generate_series(
    '2024-01-01'::DATE,
    '2026-12-31'::DATE,
    '1 day'::INTERVAL
) AS d
ON CONFLICT (fecha) DO NOTHING;

-- ===========================================================================
-- CARGA INICIAL DE dim_tiempo (ejecutar UNA sola vez)
-- Solo 24 filas: una por hora del dia (0-23)
-- ===========================================================================
INSERT INTO dim_tiempo (hora, franja_horaria)
SELECT
    h AS hora,
    CASE
        WHEN h BETWEEN 0  AND 5  THEN 'Madrugada'
        WHEN h BETWEEN 6  AND 11 THEN 'Manana'
        WHEN h BETWEEN 12 AND 17 THEN 'Tarde'
        WHEN h BETWEEN 18 AND 22 THEN 'Pico'
        ELSE                          'Noche'
    END AS franja_horaria
FROM generate_series(0, 23) AS h
ON CONFLICT (hora) DO NOTHING;