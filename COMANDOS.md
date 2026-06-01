# Guía de Defensa — Smart Grid ELT Pipeline

> Proyecto de Gestión de Datos — Prof. Armen Djenanian
> Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)

---

## TL;DR — El proyecto en 30 segundos

Construimos un **Data Warehouse analítico** para medir la calidad del suministro eléctrico de una ciudad usando los indicadores **SAIDI**, **SAIFI** y **CAIDI** (estándar IEEE 1366).

El pipeline es **ELT**: n8n inyecta datos crudos a PostgreSQL, y los Stored Procedures transforman dentro de la base. Power BI se conecta a vistas analíticas pre-calculadas.

---

## Arquitectura general

```
Medidores (IoT)
      │
      ▼  HTTP POST
┌─────────────┐
│    n8n      │  Webhooks públicos
│  (orquesta) │  ├─ /ingesta-eventos
└──────┬──────┘  └─ /ingesta-telemetria
       │ INSERT en staging
       ▼
┌──────────────────────────────────────────┐
│         PostgreSQL (Data Warehouse)       │
│                                          │
│  ┌──────────┐   ┌──────────────────┐     │
│  │ staging  │──▶│  SPs de          │     │
│  │ eventos  │   │  reconciliación  │     │
│  │ telemetr.│   │  (idempotentes)  │     │
│  └──────────┘   └───────┬──────────┘     │
│                         ▼                │
│  ┌──────────────────────────────────┐    │
│  │  fact_interrupciones (SAIDI)     │    │
│  │  fact_telemetria     (consumo)   │    │
│  │  err_telemetria      (errores)   │    │
│  └──────────────────────────────────┘    │
│                         │                │
│  ┌──────────────────────────────────┐    │
│  │  Vistas analíticas (vw_*)        │    │
│  │  Listas para Power BI            │    │
│  └──────────────────────────────────┘    │
└──────────────────────────────────────────┘
       │
       ▼  SQL / Import
┌─────────────┐
│  Power BI   │  Dashboards tácticos y estratégicos
└─────────────┘
```

### Principio clave: ELT, no ETL

La transformación ocurre **dentro de PostgreSQL**, no en n8n. Esto es deliberado:

| Capa | Qué hace | Dónde |
|------|----------|-------|
| **E**xtract | n8n recibe HTTP POST de medidores | n8n webhook |
| **L**oad | n8n INSERT en tablas staging | PostgreSQL staging |
| **T**ransform | SPs procesan lotes dentro de la DB | PostgreSQL SP |
| **L**oad (analítico) | Power BI consume vistas | PostgreSQL views |

**Ventaja**: PostgreSQL procesa conjuntos de datos órdenes de magnitud más rápido que mover datos a n8n y volver.

---

## Modelo de datos (Estrella)

### Dimensiones

| Tabla | Granularidad | Filas | Uso |
|-------|-------------|-------|-----|
| `dim_fecha` | Día | 1,096 (2024-2026) | Agregaciones por año/mes/día |
| `dim_tiempo` | Hora | 24 (0-23) | Heatmap hora × día_semana |
| `dim_red_electrica` | Medidor | 92 | Jerarquía: subestación → circuito → transformador |
| `dim_geografia_urbana` | Sector | 8 | Drill-down geográfico |
| `dim_clientes_inventario` | Versión SCD2 | 2 | Denominador dinámico SAIDI/SAIFI |
| `dim_tipo_evento` | Código | 7 | Clasificación de eventos (severidad, criticidad) |

### Tablas de hechos

| Tabla | Filas (seed) | Qué mide |
|-------|-------------|----------|
| `fact_interrupciones` | **2,659** | Cada interrupción: duración, clientes afectados, SKs |
| `fact_telemetria` | **4,416** | Lectura horaria: consumo_kWh, voltaje |
| `err_telemetria` | **20+** | Eventos inválidos: huérfanos, voltaje fuera de rango, consumo negativo |

### Staging (punto de entrada de n8n)

| Tabla | Función |
|-------|---------|
| `staging_eventos` | Llegan los eventos POWER_OUTAGE / POWER_RESTORATION |
| `staging_telemetria` | Llegan las lecturas periódicas de consumo y voltaje |

---

## Lógica de los Stored Procedures

### `sp_reconciliar_interrupciones`

El SP más importante. Hace esto en cada lote:

```
staging_eventos (crudo)
      │
      ▼  BLOQUE 1
  Detectar RESTORATION huérfanas
  → err_telemetria y marcar procesado
      │
      ▼  BLOQUE 2 (cursor)
  Por cada medidor, ordenado por timestamp:
  ┌──────────────────────────────────────┐
  │ OUTAGE + RESTORATION → PAR VÁLIDO    │──▶ fact_interrupciones
  │   ¿duración < 5 min? → TRANSTORIO    │──▶ se salta (no va a fact)
  │   ¿ya existe? → DUPLICADO            │──▶ se salta (idempotencia)
  │                                      │
  │ OUTAGE solo → OUTAGE_ABIERTO         │──▶ se deja para próximo lote
  │                                      │
  │ RESTORATION sola → RESTAURACIÓN      │
  │ (escapó del BLOQUE 1)                │──▶ err_telemetria
  │                                      │
  │ DOS OUTAGE seguidas → DOBLE_OUTAGE   │──▶ err_telemetria
  │                                      │
  │ DOS RESTORATION seguidas → DOBLE     │
  │ RESTAURACIÓN                         │──▶ err_telemetria
  └──────────────────────────────────────┘
      │
      ▼  BLOQUE 3
  Actualizar ctrl_lotes_procesamiento
  RAISE NOTICE con resumen
```

**Idempotencia**: si ejecutás el SP 10 veces, produce el mismo resultado que 1 vez. Los eventos ya procesados tienen `procesado = TRUE`.

### `sp_reconciliar_telemetria`

Más simple, basado en conjunto (no cursor):

```
staging_telemetria (crudo)
      │
      ▼  BLOQUE 1: Validaciones
  ┌──────────────────────────────────┐
  │ Medidor inactivo?                │──▶ err_telemetria + procesado
  │ Consumo negativo (<0)?           │──▶ err_telemetria + procesado
  │ Voltaje fuera de rango (0-1000)? │──▶ err_telemetria (aviso, NO excluye)
  └──────────────────────────────────┘
      │
      ▼  BLOQUE 2: Bulk INSERT
  INSERT INTO fact_telemetria ... SELECT ...
  JOIN dim_fecha + dim_tiempo + dim_red_electrica
  ON CONFLICT (sk_red_electrica, sk_fecha, sk_tiempo) DO NOTHING
      │
      ▼  BLOQUE 3: Marcar procesados + auditoría
```

### Wrapper JSON para n8n

`fn_reconciliar_interrupciones()` y `fn_reconciliar_telemetria()` devuelven JSONB:

```json
{"estado": "COMPLETADO", "lote_id": 1, "total_hechos": 42, "total_eventos": 97, ...}
```

---

## Vistas analíticas (para Power BI)

| Vista | Filas | Qué muestra |
|-------|-------|-------------|
| `vw_saidi_saifi_mensual` | 84 | **Vista principal**. SAIDI/SAIFI/CAIDI mensual con jerarquía subestación→circuito→transformador. Excluye MED. |
| `vw_saidi_saifi_con_med` | 1,096 | SAIDI diario con bandera `es_med` para slicer en Power BI |
| `vw_consumo_diario` | 126 | Consumo kWh por geografía con GROUPING SETS |
| `vw_voltaje_tendencia` | 4 | Tendencia de voltaje por transformador con flag `fluctuacion_excesiva` |
| `vw_heatmap_interrupciones` | 167 | Matriz hora × día_semana para heatmap |
| `vw_ranking_subestaciones` | 3 | Ranking con semáforo (CRÍTICO/ALTO/MEDIO/NORMAL) |
| `vw_tendencia_12_meses` | 3 | Tendencia 24 meses con variación intermensual |
| `vw_auditoria_errores` | ~3 | Evolución de errores de ingesta |
| `vw_monitoreo_elt` | ~3 | Salud del pipeline (tasa de conversión, errores) |

### MED Days (IEEE 1366, método 2.5 Beta)

Días catastróficos (tormentas, apagones masivos) que distorsionan los indicadores. El algoritmo:

1. Calcular SAIDI diario para todo el histórico
2. Tomar ln(SAIDI) de los días con SAIDI > 0
3. α = media, β = desviación estándar de los ln
4. **Umbral T_MED = exp(α + 2.5 × β)**
5. Días con SAIDI > T_MED → Major Event Day

Implementado en `fn_calcular_umbral_med()` (STABLE, se optimiza en subconsultas).

---

## Demostración rápida (10 minutos)

### 1. Mostrar la base vacía (opcional)

```sql
SELECT COUNT(*) AS staging_eventos FROM staging_eventos;
SELECT COUNT(*) AS fact_interrupciones FROM fact_interrupciones;
```

### 2. Inyectar datos con los webhooks

```bash
# --- Eventos: par normal ---
curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-eventos \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":5,"tipo_evento":"POWER_OUTAGE","timestamp_evento":"2026-06-01T14:00:00Z"}'

curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-eventos \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":5,"tipo_evento":"POWER_RESTORATION","timestamp_evento":"2026-06-01T14:35:00Z"}'

# --- Eventos: transitorio (< 5 min, el SP lo filtra) ---
curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-eventos \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":8,"tipo_evento":"POWER_OUTAGE","timestamp_evento":"2026-06-01T15:00:00Z"}'

curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-eventos \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":8,"tipo_evento":"POWER_RESTORATION","timestamp_evento":"2026-06-01T15:03:00Z"}'

# --- Eventos: RESTORATION huérfana (sin OUTAGE) ---
curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-eventos \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":12,"tipo_evento":"POWER_RESTORATION","timestamp_evento":"2026-06-01T16:00:00Z"}'

# --- Eventos: tipo desconocido (se normaliza a UNKNOWN) ---
curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-eventos \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":3,"tipo_evento":"TERREMOTO","timestamp_evento":"2026-06-01T17:00:00Z"}'

# --- Telemetría: lectura normal ---
curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-telemetria \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":5,"timestamp_lectura":"2026-06-01T14:00:00Z","consumo_wh":2500,"voltaje":220}'

# --- Telemetría: voltaje fuera de rango (>260V) ---
curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-telemetria \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":5,"timestamp_lectura":"2026-06-01T15:00:00Z","consumo_wh":2300,"voltaje":310}'

# --- Telemetría: consumo NEGATIVO (el SP lo desvía a err_telemetria) ---
curl -s -X POST https://n8n.odjaramillo.dev/webhook/ingesta-telemetria \
  -H "Content-Type: application/json" \
  -d '{"id_medidor":5,"timestamp_lectura":"2026-06-01T16:00:00Z","consumo_wh":-500,"voltaje":220}'
```

> **Respuesta esperada**: `{"recibidos":1,"estado":"en_staging"}` en todos.

### 3. Ejecutar la reconciliación (o esperar al cron)

```sql
-- Ver eventos en staging
SELECT COUNT(*) AS pendientes FROM staging_eventos WHERE procesado = FALSE;
SELECT COUNT(*) AS pendientes FROM staging_telemetria WHERE procesado = FALSE;

-- Reconciliar interrupciones
SELECT * FROM fn_reconciliar_interrupciones(
    '2026-06-01'::TIMESTAMPTZ,
    '2026-06-02'::TIMESTAMPTZ
);

-- Reconciliar telemetría
SELECT * FROM fn_reconciliar_telemetria(
    '2026-06-01'::TIMESTAMPTZ,
    '2026-06-02'::TIMESTAMPTZ
);
```

### 4. Verificar los resultados

```sql
-- Nuevos hechos
SELECT COUNT(*) AS nuevas_interrupciones FROM fact_interrupciones
WHERE id_lote_procesamiento = (SELECT MAX(id_lote) FROM ctrl_lotes_procesamiento);

-- Errores atrapados
SELECT tipo_error, COUNT(*) FROM err_telemetria
WHERE id_lote_procesamiento = (SELECT MAX(id_lote) FROM ctrl_lotes_procesamiento)
GROUP BY tipo_error;

-- Monitoreo ELT
SELECT * FROM vw_monitoreo_elt ORDER BY id_lote DESC LIMIT 3;

-- Power BI: vista principal
SELECT subestacion, periodo, saidi, saifi, caidi
FROM vw_saidi_saifi_mensual
WHERE subestacion IS NOT NULL
ORDER BY periodo DESC, subestacion
LIMIT 10;
```

---

## Escenarios de borde (para preguntas del jurado)

| Escenario | Dónde se prueba | Qué demuestra |
|-----------|----------------|---------------|
| OUTAGE + RESTORATION normal | Curl 1a | Happy path |
| Duración < 5 min | Curl 1b | Filtro IEEE 1366 (transitorios no cuentan para SAIDI) |
| RESTORATION sin OUTAGE | Curl 1c | Detección de huérfanos → err_telemetria |
| Tipo inválido (`TERREMOTO`) | Curl 1d | Normalización a UNKNOWN + logging |
| Voltaje > 260V | Curl 2b | Advertencia en err_telemetria (no excluye del hecho) |
| Consumo negativo | Curl 2c | Validación del SP → err_telemetria (excluido) |
| Idempotencia | Ejecutar SP 2 veces | 0 hechos nuevos en la 2da ejecución |
| SCD Tipo 2 | Seed: 2 versiones de inventario | Denominador dinámico SAIDI |
| MED Days | Datos históricos | Exclusión de días catastróficos del KPI rutinario |

---

## Puntos clave para la defensa

### ¿Por qué PostgreSQL y no Python/Pandas?

Porque PostgreSQL es un **motor de conjuntos**. Un `SELECT ... JOIN ... GROUP BY` procesa millones de filas con índices BRIN sin mover datos a memoria externa. Mover datos a n8n para transformarlos y devolverlos sería un antipatrón de latencia y costo de red.

### ¿Por qué estrella y no 3NF?

Porque Power BI (y cualquier BI) funciona órdenes de magnitud mejor con esquemas en estrella. El modelo 3NF normaliza pero hace que cada consulta requiera 12 JOINs. En estrella, las tablas de hechos se unen a dimensiones desnormalizadas en 1-2 JOINs.

### ¿Por qué SCD Tipo 2 en clientes?

Porque si el inventario de clientes cambia, un SAIDI de 2023 debe usar el total de clientes de 2023, no el actual. SCD Tipo 2 mantiene la historia con `[fecha_inicio, fecha_fin)`.

### Idempotencia

Si n8n llama al SP 5 veces porque hubo un timeout falso, la 2da ejecución produce 0 hechos nuevos. Los eventos ya procesados tienen `procesado = TRUE`, y los ON CONFLICT DO NOTHING previenen duplicados.

### Costo de Supabase (Free Tier)

El seed completo con 90 días y 92 medidores ocupa ~5-8 MB. Supabase free da 50 MB. Hay margen para 500 medidores × 12 meses sin problema.

---

## Glosario para la defensa

| Término | Definición |
|---------|-----------|
| **SAIDI** | System Average Interruption Duration Index. Minutos de interrupción por cliente servido. |
| **SAIFI** | System Average Interruption Frequency Index. Interrupciones por cliente servido. |
| **CAIDI** | Customer Average Interruption Duration Index. Duración promedio de cada interrupción. |
| **MED** | Major Event Day. Día catastrófico excluido del KPI rutinario (IEEE 1366). |
| **IEEE 1366** | Estándar de la IEEE para métricas de confiabilidad en distribución eléctrica. |
| **ELT** | Extract, Load, Transform. La transformación ocurre dentro de la base de datos. |
| **SCD Tipo 2** | Slowly Changing Dimension. Mantiene historia de cambios con fechas de vigencia. |
| **BRIN Index** | Block Range Index. Índice liviano para datos ordenados temporalmente (ideal para timestamps). |
| **SK** | Surrogate Key. Identificador artificial de dimensión (BIGINT auto-generado). |

---

## Archivos del proyecto

| Archivo | Qué contiene |
|---------|-------------|
| `01-ddl-modelo-estrella.sql` | DDL completo: tablas, índices, secuencias, carga dim_fecha/dim_tiempo |
| `02-sp-reconciliacion-elt.sql` | `sp_reconciliar_interrupciones`, `sp_reconciliar_telemetria`, wrappers JSON |
| `03-vistas-analiticas.sql` | 10 vistas analíticas + `fn_calcular_umbral_med()` + `fn_actualizar_flag_med()` |
| `04-datos-semilla.sql` | Seed con 92 medidores, 3 subestaciones, 90 días de datos |
| `05-verificacion-smoke-test.sql` | Smoke test con 7 secciones de validación |
| `generar_datos_semilla.py` | Generador de seed data (--days, --meters, --seed) |

---

## Diagrama de la defensa (orden sugerido)

```
1.  CONTEXTO     →  "Medimos resiliencia eléctrica con SAIDI/SAIFI"
2.  ARQUITECTURA →  ELT: n8n → staging → SPs → views → Power BI
3.  MODELO       →  Estrella: dim_fecha + dim_tiempo separadas
4.  SPs          →  Mostrar sp_reconciliar_interrupciones (el más complejo)
5.  DEMO         →  Curls → verificar en BD → abrir Power BI
6.  EDGE CASES   →  Huérfanos, transitorios, consumo negativo
7.  CIERRE       →  Idempotencia, SCD2, MED, costo free tier
```
