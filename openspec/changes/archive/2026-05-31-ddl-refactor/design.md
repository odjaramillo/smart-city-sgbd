# Technical Design: Refactorización Arquitectónica del DDL

**Change**: ddl-refactor
**Date**: 2026-05-31
**Status**: DESIGN

---

## 1. Architecture Overview

### Two-Fact Constellation Schema

El modelo evoluciona de un **star schema simple** (una fact table) a un **constellation schema** (dos fact tables compartiendo dimensiones). Esto respeta la regla de oro de Kimball: **grano uniforme por fact table**.

```
                    ┌─────────────────────┐
                    │   dim_tiempo        │
                    │   (minuto)          │
                    └──────────┬──────────┘
                               │
         ┌─────────────────────┼─────────────────────┐
         │                     │                     │
         ▼                     ▼                     ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐
│ fact_telemetria │  │fact_interrupciones│ │  dim_tipo_evento    │
│ (hourly grain)  │  │(outage pairs)    │  │  (Stress Test)      │
│ - consumo_kwh   │  │- duracion_min    │  │  - severidad        │
│ - voltaje       │  │- clientes_afect  │  │  - es_critico       │
└─────────────────┘  └─────────────────┘  └─────────────────────┘
         │                     │                     │
         └─────────────────────┼─────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
    ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
    │dim_red_elec  │  │dim_geografia │  │dim_clientes_inv  │
    │(SCD2)        │  │urbana        │  │(SCD2)            │
    └──────────────┘  └──────────────┘  └──────────────────┘
```

### Data Flow

```
n8n (IoT sensors)
    │
    ├─→ Interruptions ──→ staging_eventos ──→ sp_reconciliar_interrupciones() ──→ fact_interrupciones
    │                                          (cursor + Window Functions)
    │
    └─→ Telemetry ────→ staging_telemetria ──→ sp_reconciliar_telemetria() ──→ fact_telemetria
                                               (set-based bulk INSERT)

PostgreSQL Views
    │
    ├─→ vw_saidi_saifi_* (from fact_interrupciones)
    ├─→ vw_consumo_diario (from fact_telemetria)
    └─→ vw_voltaje_tendencia (from fact_telemetria)

Power BI
    │
    └─→ Import views directly (query folding enabled)
```

---

## 2. DDL Structure

### 2.1 New Tables

#### `dim_tipo_evento` (Event Type Catalog)

```sql
CREATE TABLE dim_tipo_evento (
    sk_tipo_evento BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_evento VARCHAR(50) NOT NULL UNIQUE,
    categoria VARCHAR(30) NOT NULL,
    severidad VARCHAR(20) NOT NULL 
        CHECK (severidad IN ('BAJA', 'MEDIA', 'ALTA', 'CRITICA', 'DESCONOCIDA')),
    es_critico BOOLEAN NOT NULL DEFAULT FALSE,
    descripcion TEXT,
    regla_vigencia_desde TIMESTAMPTZ,
    regla_vigencia_hasta TIMESTAMPTZ
);

-- Índices
CREATE INDEX idx_dim_tipo_evento_categoria ON dim_tipo_evento (categoria);

-- Fila obligatoria -1 (Unknown) — insertada en 04-datos-semilla.sql
-- Reset sequence después del insert manual
```

**Key columns**:
- `codigo_evento`: UNIQUE, usado para lookup desde staging (ej: 'POWER_OUTAGE', 'VOLTAGE_SPIKE')
- `categoria`: 'INTERRUPCION', 'FLUCTUACION', 'TELEMETRIA' (para filtrado en vistas)
- `severidad`: 'BAJA', 'MEDIA', 'ALTA', 'CRITICA' (para Stress Test)
- `es_critico`: BOOLEAN para alertas rápidas
- `regla_vigencia_desde/hasta`: TIMESTAMPTZ para auditoría de cambios de reglas

---

#### `staging_telemetria` (Telemetry Landing Zone)

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

**Key columns**:
- `consumo_wh`: en Wh (el SP convierte a kWh)
- `voltaje`: en V, validado 0-1000V
- `tipo_lectura`: discriminador para diferentes fuentes de telemetría
- `procesado`: flag para idempotencia

---

#### `fact_telemetria` (Periodic Snapshot — Hourly)

```sql
CREATE TABLE fact_telemetria (
    sk_telemetria BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sk_tiempo BIGINT NOT NULL REFERENCES dim_tiempo(sk_tiempo),
    sk_red_electrica BIGINT NOT NULL REFERENCES dim_red_electrica(sk_red_electrica),
    sk_geografia_urbana BIGINT NOT NULL REFERENCES dim_geografia_urbana(sk_geografia_urbana),
    sk_tipo_evento BIGINT NOT NULL DEFAULT -1 
        REFERENCES dim_tipo_evento(sk_tipo_evento) ON DELETE SET DEFAULT,
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
CREATE INDEX idx_fact_telemetria_sk_tipo ON fact_telemetria (sk_tipo_evento);

-- Unique: una lectura por medidor por hora
CREATE UNIQUE INDEX uq_fact_telemetria_medidor_hora 
ON fact_telemetria (sk_red_electrica, DATE_TRUNC('hour', timestamp_lectura));
```

**Key columns**:
- `consumo_kwh`: convertido desde Wh en staging
- `voltaje`: en V
- `timestamp_lectura`: truncado a hora para granularidad horaria
- UNIQUE constraint previene duplicados (medidor + hora)

---

### 2.2 Updated Tables

#### `fact_interrupciones` (Add FK to dim_tipo_evento)

```sql
-- En reescritura completa, incluir directamente en CREATE TABLE
ALTER TABLE fact_interrupciones 
ADD COLUMN sk_tipo_evento BIGINT NOT NULL DEFAULT -1 
    REFERENCES dim_tipo_evento(sk_tipo_evento) ON DELETE SET DEFAULT;

CREATE INDEX idx_fact_interrupciones_tipo ON fact_interrupciones (sk_tipo_evento);
```

**Impact**: Permite filtrar SAIDI/SAIFI por severidad/categoria (ej: "SAIDI solo eventos CRITICOS").

---

#### `staging_eventos` (Expand CHECK Constraint)

```sql
-- En reescritura completa, incluir directamente en CREATE TABLE
tipo_evento VARCHAR(50) NOT NULL 
    CHECK (tipo_evento IN (
        'POWER_OUTAGE', 'POWER_RESTORATION', 
        'VOLTAGE_SPIKE', 'VOLTAGE_SAG', 
        'HEARTBEAT', 'UNKNOWN'
    ))
```

**Impact**: Permite ingerir más tipos de evento, alineado con catálogo de dim_tipo_evento.

---

#### `err_telemetria` (Add tipo_error Discriminator)

```sql
-- En reescritura completa, incluir directamente en CREATE TABLE
ALTER TABLE err_telemetria 
ADD COLUMN tipo_error VARCHAR(50) NOT NULL DEFAULT 'INTERRUPCION' 
    CHECK (tipo_error IN (
        'INTERRUPCION', 'RESTAURACION_HUERFANA', 'CORTE_HUERFANO',
        'TELEMETRIA', 'VOLTAGE_OUT_OF_RANGE', 'CONSUMO_NEGATIVO',
        'EVENTO_DESCONOCIDO', 'MEDIDOR_INACTIVO', 'DUPLICADO'
    ));

CREATE INDEX idx_err_telemetria_tipo ON err_telemetria (tipo_error);
```

**Impact**: Permite consultas separadas por pipeline (interrupciones vs telemetría).

---

## 3. Stored Procedure Design

### 3.1 New: `sp_reconciliar_telemetria()`

**Purpose**: Set-based bulk INSERT desde staging_telemetria a fact_telemetria.

**Algorithm**:
1. **Bloque 0**: Inicialización de lote (igual que sp_reconciliar_interrupciones)
2. **Bloque 1**: Validación y desvío de errores
   - Voltaje fuera de rango (180-260V normal, 0-1000V aceptable) → err_telemetria
   - Consumo negativo → err_telemetria
   - Medidor inactivo (no en dim_red_electrica o activo_bool=FALSE) → err_telemetria
3. **Bloque 2**: Bulk INSERT con conversión de unidades y resolución de SKs
   - Convertir consumo_wh → consumo_kwh (÷ 1000)
   - Resolver sk_tiempo: DATE_TRUNC('hour', timestamp_lectura) → dim_tiempo.sk_tiempo
   - Resolver sk_red_electrica: lookup por id_medidor + fecha_inicio <= timestamp
   - Resolver sk_geografia_urbana: JOIN dim_red_electrica → dim_geografia_urbana
   - Resolver sk_tipo_evento: lookup por tipo_lectura → dim_tipo_evento.codigo_evento
   - INSERT INTO fact_telemetria (ON CONFLICT DO NOTHING para duplicados)
4. **Bloque 3**: Marcar staging_telemetria.procesado = TRUE, actualizar ctrl_lotes_procesamiento

**Key differences from sp_reconciliar_interrupciones**:
- **No cursor**: pure set-based INSERT (más rápido, más simple)
- **No pair matching**: cada lectura es independiente
- **Unit conversion**: Wh → kWh

**Pseudocode**:
```sql
INSERT INTO fact_telemetria (
    sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_tipo_evento,
    timestamp_lectura, consumo_kwh, voltaje, id_lote_procesamiento
)
SELECT
    dt.sk_tiempo,
    dre.sk_red_electrica,
    dgu.sk_geografia_urbana,
    COALESCE(dte.sk_tipo_evento, -1),
    DATE_TRUNC('hour', st.timestamp_lectura),
    st.consumo_wh / 1000.0,  -- Conversión Wh → kWh
    st.voltaje,
    v_lote_id
FROM staging_telemetria st
JOIN dim_tiempo dt 
    ON dt.timestamp_completo = DATE_TRUNC('hour', st.timestamp_lectura)
JOIN dim_red_electrica dre 
    ON dre.id_medidor_origen = st.id_medidor
    AND dre.fecha_inicio <= st.timestamp_lectura
    AND (dre.fecha_fin IS NULL OR dre.fecha_fin > st.timestamp_lectura)
JOIN dim_geografia_urbana dgu 
    ON dgu.sk_geografia_urbana = dre.sk_geografia_urbana  -- Asumir FK en dim_red_electrica
LEFT JOIN dim_tipo_evento dte 
    ON dte.codigo_evento = st.tipo_lectura
WHERE st.procesado = FALSE
  AND st.voltaje BETWEEN 0 AND 1000
  AND st.consumo_wh >= 0
ON CONFLICT (sk_red_electrica, DATE_TRUNC('hour', timestamp_lectura)) DO NOTHING;
```

---

### 3.2 Updated: `sp_reconciliar_interrupciones()`

**Changes**:
1. **Resolver sk_tipo_evento**: Agregar lookup en Bloque 2 (antes de INSERT en fact_interrupciones)
   ```sql
   SELECT sk_tipo_evento INTO v_sk_tipo_evento
   FROM dim_tipo_evento
   WHERE codigo_evento = v_rec.tipo_evento;
   
   IF v_sk_tipo_evento IS NULL THEN
       v_sk_tipo_evento := -1;  -- Unknown
       INSERT INTO err_telemetria (... tipo_error='EVENTO_DESCONOCIDO' ...);
   END IF;
   ```

2. **Agregar sk_tipo_evento al INSERT**:
   ```sql
   INSERT INTO fact_interrupciones (
       sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes,
       sk_tipo_evento,  -- NUEVA COLUMNA
       id_medidor, timestamp_inicio, timestamp_fin, ...
   ) VALUES (
       v_sk_tiempo, v_sk_red, v_sk_geo, v_sk_clientes,
       v_sk_tipo_evento,  -- NUEVO VALOR
       v_rec.id_medidor, v_rec.ts_outage, v_rec.ts_restoration, ...
   );
   ```

3. **Expandir CHECK constraint en staging_eventos**: Ya incluido en DDL (no requiere cambio en SP)

---

## 4. View Design

### 4.1 New Views (Telemetry)

#### `vw_consumo_diario` (Daily Consumption Aggregation)

```sql
CREATE OR REPLACE VIEW vw_consumo_diario AS
SELECT
    dt.anio,
    dt.mes,
    dt.dia,
    dt.timestamp_completo::DATE AS fecha,
    dre.subestacion,
    dre.circuito,
    dgu.sector_urbano,
    COUNT(ft.sk_telemetria) AS total_lecturas,
    SUM(ft.consumo_kwh) AS consumo_total_kwh,
    AVG(ft.consumo_kwh) AS consumo_promedio_kwh,
    MAX(ft.consumo_kwh) AS consumo_maximo_kwh,
    MIN(ft.consumo_kwh) AS consumo_minimo_kwh
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
```

**Use case**: Power BI dashboard de consumo energético con drill-down por geografía.

---

#### `vw_voltaje_tendencia` (Voltage Trend by Transformer)

```sql
CREATE OR REPLACE VIEW vw_voltaje_tendencia AS
SELECT
    dt.anio,
    dt.mes,
    dre.subestacion,
    dre.circuito,
    dre.transformador,
    COUNT(ft.sk_telemetria) AS total_lecturas,
    ROUND(AVG(ft.voltaje)::NUMERIC, 2) AS voltaje_promedio,
    ROUND(STDDEV(ft.voltaje)::NUMERIC, 2) AS voltaje_desviacion,
    MIN(ft.voltaje) AS voltaje_minimo,
    MAX(ft.voltaje) AS voltaje_maximo,
    -- Flag de fluctuación excesiva (desviación > 5% del promedio)
    CASE 
        WHEN STDDEV(ft.voltaje) / NULLIF(AVG(ft.voltaje), 0) > 0.05 
        THEN TRUE ELSE FALSE 
    END AS fluctuacion_excesiva
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
```

**Use case**: Detección de transformadores con problemas de voltaje (fluctuación excesiva).

---

### 4.2 Updated Views (SAIDI/SAIFI)

#### `vw_saidi_saifi_diario` (Add JOIN to dim_tipo_evento)

**Change**: Agregar JOIN opcional a dim_tipo_evento para permitir filtrado por severidad/categoria.

```sql
CREATE OR REPLACE VIEW vw_saidi_saifi_diario AS
SELECT
    dt.anio,
    dt.mes,
    dt.nombre_mes,
    dt.trimestre,
    dt.dia,
    dt.timestamp_completo::DATE AS fecha,
    
    -- NUEVO: Atributos de tipo de evento (para slicers en Power BI)
    dte.categoria,
    dte.severidad,
    dte.es_critico,
    
    -- Métricas de interrupción (sin cambios)
    COUNT(fi.sk_interrupcion) AS total_interrupciones,
    COALESCE(SUM(fi.duracion_minutos * fi.clientes_afectados), 0) AS suma_minutos_cliente,
    MAX(ci.total_clientes_servidos) AS total_clientes_servidos,
    
    -- SAIDI/SAIFI (sin cambios)
    CASE WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(COALESCE(SUM(fi.duracion_minutos * fi.clientes_afectados), 0) 
                   / MAX(ci.total_clientes_servidos)::NUMERIC, 4)
        ELSE 0
    END AS saidi_diario,
    CASE WHEN MAX(ci.total_clientes_servidos) > 0
        THEN ROUND(COUNT(fi.sk_interrupcion)::NUMERIC 
                   / MAX(ci.total_clientes_servidos)::NUMERIC, 4)
        ELSE 0
    END AS saifi_diario

FROM dim_tiempo dt
LEFT JOIN fact_interrupciones fi
    ON fi.sk_tiempo = dt.sk_tiempo
    AND fi.excluido_med = FALSE
LEFT JOIN dim_tipo_evento dte  -- NUEVO JOIN
    ON fi.sk_tipo_evento = dte.sk_tipo_evento
LEFT JOIN dim_clientes_inventario ci
    ON ci.fecha_inicio <= dt.timestamp_completo
    AND (ci.fecha_fin IS NULL OR ci.fecha_fin > dt.timestamp_completo)
    AND ci.activo_bool = TRUE

GROUP BY
    dt.anio, dt.mes, dt.nombre_mes, dt.trimestre,
    dt.dia, dt.timestamp_completo::DATE,
    dte.categoria, dte.severidad, dte.es_critico  -- NUEVO en GROUP BY

ORDER BY fecha DESC;
```

**Impact**: Power BI puede crear slicers por `severidad` o `es_critico` para filtrar SAIDI/SAIFI.

**Nota**: Las vistas derivadas (`vw_saidi_saifi_con_med`, `vw_saidi_saifi_mensual`, etc.) no requieren cambios porque ya heredan de `vw_saidi_saifi_diario`.

---

## 5. Seed Data Strategy

### 5.1 `dim_tipo_evento` Catalog

**File**: `04-datos-semilla.sql`

```sql
-- Fila obligatoria -1 (Unknown)
INSERT INTO dim_tipo_evento (sk_tipo_evento, codigo_evento, categoria, severidad, es_critico, descripcion)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'UNKNOWN', 'DESCONOCIDO', 'DESCONOCIDA', FALSE, 'Tipo de evento no reconocido');

-- Reset sequence
SELECT setval('dim_tipo_evento_sk_tipo_evento_seq', 1, false);

-- Catálogo de eventos
INSERT INTO dim_tipo_evento (codigo_evento, categoria, severidad, es_critico, descripcion) VALUES
('POWER_OUTAGE', 'INTERRUPCION', 'ALTA', TRUE, 'Corte de energía detectado por smart meter'),
('POWER_RESTORATION', 'INTERRUPCION', 'MEDIA', FALSE, 'Restauración de energía'),
('VOLTAGE_SPIKE', 'FLUCTUACION', 'ALTA', TRUE, 'Pico de voltaje (>260V)'),
('VOLTAGE_SAG', 'FLUCTUACION', 'MEDIA', FALSE, 'Caída de voltaje (<180V)'),
('HEARTBEAT', 'TELEMETRIA', 'BAJA', FALSE, 'Señal de vida del medidor'),
('LECTURA_PERIODICA', 'TELEMETRIA', 'BAJA', FALSE, 'Lectura periódica de consumo/voltaje');
```

**Execution order**: Debe ejecutarse ANTES de cualquier carga de datos en fact tables.

---

### 5.2 `staging_telemetria` Examples

**File**: `04-datos-semilla.sql`

```sql
-- Ejemplos de lecturas de telemetría (últimas 24 horas)
INSERT INTO staging_telemetria (id_medidor, timestamp_lectura, consumo_wh, voltaje, tipo_lectura) VALUES
(1001, NOW() - INTERVAL '23 hours', 2500, 220, 'LECTURA_PERIODICA'),
(1001, NOW() - INTERVAL '22 hours', 2300, 221, 'LECTURA_PERIODICA'),
(1002, NOW() - INTERVAL '23 hours', 1800, 219, 'LECTURA_PERIODICA'),
(1002, NOW() - INTERVAL '22 hours', 1900, 218, 'LECTURA_PERIODICA');
```

---

## 6. Execution Order (Migration Strategy)

### Dependencies

```
1. dim_tipo_evento (NEW) — must exist before fact tables (FK dependency)
2. staging_telemetria (NEW) — no dependencies
3. fact_telemetria (NEW) — depends on dim_tiempo, dim_red_electrica, dim_geografia_urbana, dim_tipo_evento
4. fact_interrupciones (UPDATE) — add column sk_tipo_evento (depends on dim_tipo_evento)
5. staging_eventos (UPDATE) — expand CHECK constraint (no dependencies)
6. err_telemetria (UPDATE) — add column tipo_error (no dependencies)
```

### Implementation Sequence

```sql
-- Fase 1: Nuevas dimensiones
CREATE TABLE dim_tipo_evento (...);
INSERT INTO dim_tipo_evento VALUES (-1, 'UNKNOWN', ...);  -- Fila obligatoria

-- Fase 2: Nuevas tablas de staging y hechos
CREATE TABLE staging_telemetria (...);
CREATE TABLE fact_telemetria (...);

-- Fase 3: Actualizar tablas existentes
ALTER TABLE fact_interrupciones ADD COLUMN sk_tipo_evento ...;
ALTER TABLE staging_eventos DROP CONSTRAINT ...;  -- Remover CHECK antiguo
ALTER TABLE staging_eventos ADD CONSTRAINT ...;   -- Agregar CHECK expandido
ALTER TABLE err_telemetria ADD COLUMN tipo_error ...;

-- Fase 4: Nuevos SPs y vistas
CREATE OR REPLACE PROCEDURE sp_reconciliar_telemetria(...);
CREATE OR REPLACE FUNCTION fn_reconciliar_telemetria(...);
CREATE OR REPLACE VIEW vw_consumo_diario AS ...;
CREATE OR REPLACE VIEW vw_voltaje_tendencia AS ...;

-- Fase 5: Actualizar SPs y vistas existentes
CREATE OR REPLACE PROCEDURE sp_reconciliar_interrupciones(...);  -- Con sk_tipo_evento
CREATE OR REPLACE VIEW vw_saidi_saifi_diario AS ...;  -- Con JOIN dim_tipo_evento
```

---

## 7. Power BI Integration

### Two-Fact Model in Power BI

**Import strategy**:
1. Import `fact_telemetria` and `fact_interrupciones` as separate tables
2. Create relationships via shared dimensions:
   - `fact_telemetria[sk_tiempo]` → `dim_tiempo[sk_tiempo]`
   - `fact_interrupciones[sk_tiempo]` → `dim_tiempo[sk_tiempo]`
   - (Similar for other dimensions)
3. Use `dim_tiempo` as a **bridge table** for cross-fact analysis

**Recommended views to import**:
- `vw_saidi_saifi_mensual` — Main KPI dashboard
- `vw_consumo_diario` — Consumption analysis
- `vw_voltaje_tendencia` — Voltage quality monitoring
- `vw_tendencia_12_meses` — Trend line charts

**DAX measures**:
```dax
// Cross-fact: consumo during interruptions
Consumo Durante Interrupciones = 
CALCULATE(
    SUM(fact_telemetria[consumo_kwh]),
    TREATAS(VALUES(fact_interrupciones[sk_tiempo]), dim_tiempo[sk_tiempo])
)

// Voltage quality
% Lecturas con Voltaje Normal = 
DIVIDE(
    CALCULATE(COUNTROWS(fact_telemetria), fact_telemetria[voltaje] >= 180 && fact_telemetria[voltaje] <= 260),
    COUNTROWS(fact_telemetria)
)
```

---

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Volume explosion** (fact_telemetria) | High | Hourly granularity = 26M rows (manageable). If needed, aggregate to daily views. |
| **FK resolution failure** (medidor not in dim_red_electrica) | Medium | SP inserts default row with 'DESCONOCIDO' hierarchy (existing pattern). |
| **Duplicate telemetry** (same medidor + hour) | Low | UNIQUE constraint rejects duplicates, logged to err_telemetria. |
| **Stress Test complexity** | Low | dim_tipo_evento UPDATE is trivial. Document execution order for professor. |
| **Power BI import size** | Medium | Use aggregated views (vw_consumo_diario) instead of raw fact_telemetria. |

---

## 9. Open Questions (Resolved)

| Question | Decision | Rationale |
|----------|----------|-----------|
| Telemetry granularity | **Hourly** | 26M rows manageable, matches smart meter industry standard |
| Staging architecture | **Two separate tables** | Clean contracts, different data shapes, simpler SPs |
| DLQ strategy | **Extend err_telemetria** | Add tipo_error discriminator, single table for all errors |
| Indexes for fact_telemetria | **BRIN on timestamp + B-Tree on FKs** | BRIN for time range queries, B-Tree for JOINs |
| Unit conversion | **SP converts Wh → kWh** | Staging stores raw (Wh), fact stores normalized (kWh) |

---

**Design written by**: SDD Orchestrator
**Date**: 2026-05-31
