# Delta Specs: Refactorización Arquitectónica del DDL

**Change**: ddl-refactor
**Date**: 2026-05-31
**Status**: SPEC

---

## ADDED Requirements

### REQ-1: Fact Telemetria (Periodic Snapshot — Hourly)

The system MUST store periodic telemetry readings in `fact_telemetria` using HOURLY granularity, capturing consumo and voltage measurements for smart meters.

#### Scenario 1.1: Hourly reading insertion
- **GIVEN** a validated telemetry reading (id_medidor=1001, timestamp=14:00, consumo_kwh=2.5, voltaje=220)
- **WHEN** inserting into `fact_telemetria`
- **THEN** the system MUST resolve all surrogate keys (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_tipo_evento)
- **AND** MUST include `consumo_kwh NUMERIC(12,4)` and `voltaje NUMERIC(8,2)` measurements
- **AND** MUST enforce UNIQUE constraint: one reading per medidor per hour

#### Scenario 1.2: Zero consumption reading
- **GIVEN** a validated telemetry reading with consumo_kwh = 0
- **WHEN** inserting into `fact_telemetria`
- **THEN** the system MUST accept the record (valid state for disconnected/inactive meters)

#### Scenario 1.3: Unit conversion
- **GIVEN** a reading with consumo in Wh (2500 Wh)
- **WHEN** the SP processes the reading
- **THEN** the system MUST convert to kWh (2.5 kWh) before insertion

#### Scenario 1.4: Voltage out of range
- **GIVEN** a reading with voltaje = 500V (outside normal 180-260V range)
- **WHEN** the SP processes the reading
- **THEN** the system MUST insert into fact_telemetria BUT log a warning in err_telemetria (tipo_error='VOLTAGE_OUT_OF_RANGE')

#### Acceptance Criteria (SQL)

```sql
CREATE TABLE fact_telemetria (
    sk_telemetria BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sk_tiempo BIGINT NOT NULL REFERENCES dim_tiempo(sk_tiempo),
    sk_red_electrica BIGINT NOT NULL REFERENCES dim_red_electrica(sk_red_electrica),
    sk_geografia_urbana BIGINT NOT NULL REFERENCES dim_geografia_urbana(sk_geografia_urbana),
    sk_tipo_evento BIGINT NOT NULL DEFAULT -1 REFERENCES dim_tipo_evento(sk_tipo_evento),
    timestamp_lectura TIMESTAMPTZ NOT NULL,
    consumo_kwh NUMERIC(12,4) NOT NULL CHECK (consumo_kwh >= 0),
    voltaje NUMERIC(8,2) NOT NULL CHECK (voltaje >= 0 AND voltaje <= 1000),
    id_lote_procesamiento BIGINT REFERENCES ctrl_lotes_procesamiento(id_lote)
);

-- Índices
CREATE INDEX idx_fact_telemetria_brin_timestamp 
ON fact_telemetria USING BRIN (timestamp_lectura) WITH (pages_per_range = 32);
CREATE INDEX idx_fact_telemetria_sk_tiempo ON fact_telemetria (sk_tiempo);
CREATE INDEX idx_fact_telemetria_sk_red ON fact_telemetria (sk_red_electrica);

-- Unique: una lectura por medidor por hora
CREATE UNIQUE INDEX uq_fact_telemetria_medidor_hora 
ON fact_telemetria (sk_red_electrica, DATE_TRUNC('hour', timestamp_lectura));
```

---

### REQ-2: Staging Telemetria (Landing Zone)

The system MUST provide a `staging_telemetria` table as a landing zone for raw periodic readings from n8n, with typed columns and early validation via CHECK constraints.

#### Scenario 2.1: Raw payload ingestion
- **GIVEN** an incoming telemetry payload from n8n (id_medidor=1001, timestamp=2024-03-15T14:00:00Z, consumo_wh=2500, voltaje=220)
- **WHEN** loading into `staging_telemetria`
- **THEN** the system MUST accept the raw data without transformation
- **AND** MUST validate data types using VARCHAR with CHECK constraints (no JSONB/ENUMs)
- **AND** MUST set procesado=FALSE, fecha_carga=NOW()

#### Scenario 2.2: Rejection of invalid tipo_lectura
- **GIVEN** a payload with tipo_lectura='INVALID_TYPE'
- **WHEN** n8n executes INSERT into staging_telemetria
- **THEN** PostgreSQL MUST reject the INSERT (CHECK constraint violation)
- **AND** n8n MUST capture the error and write to err_telemetria

#### Acceptance Criteria (SQL)

```sql
CREATE TABLE staging_telemetria (
    id_staging BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_medidor BIGINT NOT NULL,
    timestamp_lectura TIMESTAMPTZ NOT NULL,
    consumo_wh NUMERIC(12,2) NOT NULL CHECK (consumo_wh >= 0),
    voltaje NUMERIC(8,2) NOT NULL CHECK (voltaje >= 0 AND voltaje <= 1000),
    tipo_lectura VARCHAR(30) NOT NULL DEFAULT 'LECTURA_PERIODICA' 
        CHECK (tipo_lectura IN ('LECTURA_PERIODICA', 'LECTURA_EVENTO', 'HEARTBEAT')),
    procesado BOOLEAN NOT NULL DEFAULT FALSE,
    fecha_carga TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    id_lote_procesamiento BIGINT
);

-- Índice compuesto para SP processing
CREATE INDEX idx_staging_telemetria_procesado 
ON staging_telemetria (procesado, id_medidor, timestamp_lectura) 
WHERE procesado = FALSE;
```

---

### REQ-3: Dimension Tipo Evento (Stress Test Catalog)

The system MUST maintain a `dim_tipo_evento` catalog supporting dynamic Stress Test rule changes without full reconstruction.

#### Scenario 3.1: Event type lookup
- **GIVEN** an event with codigo_evento='POWER_OUTAGE'
- **WHEN** joining with `dim_tipo_evento`
- **THEN** the system MUST return categoria='INTERRUPCION', severidad='ALTA', es_critico=TRUE

#### Scenario 3.2: Unknown event handling
- **GIVEN** an event with unrecognized codigo_evento='TIPO_DESCONOCIDO'
- **WHEN** resolving the dimension key
- **THEN** the system MUST link to sk_tipo_evento = -1 (Unknown)
- **AND** MUST log warning in err_telemetria (tipo_error='EVENTO_DESCONOCIDO')

#### Scenario 3.3: Stress Test — live rule change
- **GIVEN** dim_tipo_evento contains codigo_evento='VOLTAGE_SPIKE' with severidad='MEDIA'
- **WHEN** professor requests change to severidad='CRITICA' during defense
- **THEN** execute: `UPDATE dim_tipo_evento SET severidad='CRITICA', es_critico=TRUE WHERE codigo_evento='VOLTAGE_SPIKE'`
- **AND** Power BI MUST reflect the change instantly in historical dashboards (FKs point to updated dimension)

#### Scenario 3.4: Filtering by categoria in analytic views
- **GIVEN** dim_tipo_evento has categorias 'INTERRUPCION', 'FLUCTUACION', 'TELEMETRIA'
- **WHEN** an analytic view filters by categoria='INTERRUPCION'
- **THEN** only interruption events are included in SAIDI/SAIFI calculation

#### Acceptance Criteria (SQL)

```sql
CREATE TABLE dim_tipo_evento (
    sk_tipo_evento BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_evento VARCHAR(50) NOT NULL UNIQUE,
    categoria VARCHAR(30) NOT NULL,
    severidad VARCHAR(20) NOT NULL CHECK (severidad IN ('BAJA', 'MEDIA', 'ALTA', 'CRITICA', 'DESCONOCIDA')),
    es_critico BOOLEAN NOT NULL DEFAULT FALSE,
    descripcion TEXT,
    regla_vigencia_desde TIMESTAMPTZ,
    regla_vigencia_hasta TIMESTAMPTZ
);

-- Fila obligatoria -1 (Unknown) — insertada en 04-datos-semilla.sql
INSERT INTO dim_tipo_evento (sk_tipo_evento, codigo_evento, categoria, severidad, es_critico, descripcion)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'UNKNOWN', 'DESCONOCIDO', 'DESCONOCIDA', FALSE, 'Tipo de evento no reconocido');

-- Reset sequence after manual insert
SELECT setval('dim_tipo_evento_sk_tipo_evento_seq', 1, false);

-- Índices
CREATE INDEX idx_dim_tipo_evento_codigo ON dim_tipo_evento (codigo_evento);
CREATE INDEX idx_dim_tipo_evento_categoria ON dim_tipo_evento (categoria);
```

---

## MODIFIED Requirements

### REQ-4: Fact Interrupciones (add FK to dim_tipo_evento)

The system MUST store interruption events in `fact_interrupciones` with a reference to the event type dimension, enabling filtering by severidad/categoria in SAIDI/SAIFI calculations.

**(Previously: ONLY captured OUTAGE→RESTORATION pairs without event type dimension)**

#### Scenario 4.1: Interruption with known event type
- **GIVEN** an accumulating snapshot for an outage with tipo_evento='POWER_OUTAGE'
- **WHEN** updating `fact_interrupciones`
- **THEN** the system MUST include sk_tipo_evento = (SELECT sk_tipo_evento FROM dim_tipo_evento WHERE codigo_evento='POWER_OUTAGE')

#### Scenario 4.2: Interruption with unknown event type
- **GIVEN** an outage with tipo_evento='TIPO_NUEVO' not in dim_tipo_evento
- **WHEN** the SP processes the pair
- **THEN** the system MUST insert with sk_tipo_evento = -1 (Unknown)
- **AND** MUST log warning in err_telemetria

#### Acceptance Criteria (SQL)

```sql
-- En reescritura completa del DDL, incluir directamente en CREATE TABLE
ALTER TABLE fact_interrupciones 
ADD COLUMN sk_tipo_evento BIGINT NOT NULL DEFAULT -1 
REFERENCES dim_tipo_evento(sk_tipo_evento) ON DELETE SET DEFAULT;

-- Índice para filtrado por tipo
CREATE INDEX idx_fact_interrupciones_tipo ON fact_interrupciones (sk_tipo_evento);
```

---

### REQ-5: Staging Eventos (expand CHECK constraint)

The system MUST validate incoming events in `staging_eventos` against an expanded set of event types, aligned with dim_tipo_evento catalog.

**(Previously: Supported only POWER_OUTAGE and POWER_RESTORATION)**

#### Scenario 5.1: Ingestion of new event type
- **GIVEN** a raw event with tipo_evento='VOLTAGE_SPIKE'
- **WHEN** loading into `staging_eventos`
- **THEN** the system MUST accept the record
- **AND** MUST validate using expanded CHECK constraint

#### Acceptance Criteria (SQL)

```sql
-- En reescritura completa del DDL, incluir directamente en CREATE TABLE
tipo_evento VARCHAR(50) NOT NULL 
    CHECK (tipo_evento IN (
        'POWER_OUTAGE', 'POWER_RESTORATION', 
        'VOLTAGE_SPIKE', 'VOLTAGE_SAG', 
        'HEARTBEAT', 'UNKNOWN'
    ))
```

**Nota**: Los valores del CHECK deben alinearse con codigo_evento de dim_tipo_evento.

---

### REQ-6: Error Telemetria (add tipo_error discriminator)

The system MUST capture failed telemetry processing records in `err_telemetria` with a specific error categorization column, enabling separate queries for interruption vs telemetry pipeline errors.

**(Previously: Captured errors without discriminator column)**

#### Scenario 6.1: DLQ routing for voltage out of range
- **GIVEN** a telemetry record with voltaje=500V
- **WHEN** routing to err_telemetria
- **THEN** the system MUST populate tipo_error='VOLTAGE_OUT_OF_RANGE'
- **AND** MUST preserve original payload in detalle_tecnico

#### Scenario 6.2: DLQ routing for orphan restoration
- **GIVEN** a POWER_RESTORATION without prior POWER_OUTAGE
- **WHEN** routing to err_telemetria
- **THEN** the system MUST populate tipo_error='RESTAURACION_HUERFANA'

#### Acceptance Criteria (SQL)

```sql
-- En reescritura completa del DDL, incluir directamente en CREATE TABLE
ALTER TABLE err_telemetria 
ADD COLUMN tipo_error VARCHAR(50) NOT NULL DEFAULT 'INTERRUPCION' 
    CHECK (tipo_error IN (
        'INTERRUPCION', 'RESTAURACION_HUERFANA', 'CORTE_HUERFANO',
        'TELEMETRIA', 'VOLTAGE_OUT_OF_RANGE', 'CONSUMO_NEGATIVO',
        'EVENTO_DESCONOCIDO', 'MEDIDOR_INACTIVO', 'DUPLICADO'
    ));

-- Índice para filtrado por tipo
CREATE INDEX idx_err_telemetria_tipo ON err_telemetria (tipo_error);
```

---

## Summary

| REQ | Type | Table | Description |
|-----|------|-------|-------------|
| 1 | Added | fact_telemetria | Periodic snapshot (consumo + voltaje, hourly) |
| 2 | Added | staging_telemetria | Landing zone for periodic readings |
| 3 | Added | dim_tipo_evento | Event catalog with Stress Test support |
| 4 | Modified | fact_interrupciones | Add FK to dim_tipo_evento |
| 5 | Modified | staging_eventos | Expand CHECK constraint for more event types |
| 6 | Modified | err_telemetria | Add tipo_error discriminator |

**Total**: 3 new tables, 3 updated tables.

---

**Spec written by**: SDD Orchestrator
**Date**: 2026-05-31
