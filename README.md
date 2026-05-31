# Smart City SGBD — Arquitectura Analítica de Resiliencia

> Proyecto académico para la materia **Gestión de Datos** (Prof. Armen Djenanian).
> Monitoreo de resiliencia energética en Smart Grids usando SAIDI/SAIFI.

---

## ¿Qué hace este sistema?

El sistema ingiere eventos de **medidores inteligentes** (smart meters) y genera
indicadores de resiliencia eléctrica:

| Indicador | Descripción |
|-----------|-------------|
| **SAIDI** | System Average Interruption Duration Index — minutos promedio sin energía por cliente |
| **SAIFI** | System Average Interruption Frequency Index — cuántas veces promedio se corta por cliente |
| **CAIDI** | Customer Average Interruption Duration Index — duración promedio de cada corte |

Estos indicadores se calculan con **denominador dinámico** (SCD Tipo 2): el total de
clientesservidos cambia históricamente, entonces un SAIDI de 2023 usa el inventario
de clientes de 2023, no el actual.

---

## 1. Deploy en otra máquina

Solo necesita Docker y ~2 minutos:

```bash
# 1. Clonar el repo
git clone <repo-url>
cd smart-city-sgbd

# 2. Crear .env con las credenciales deseadas
echo "POSTGRES_DB=ucab_project" > .env
echo "POSTGRES_USER=ucab" >> .env
echo "POSTGRES_PASSWORD=ucab123" >> .env

# 3. Reset completo (levanta BD + carga esquema + povoa seed)
bash scripts/reset-db.sh

# 4. Listo. Conectar Power BI en localhost:5432
```

Connection string para Power BI / DBeaver / pgAdmin:
```
Host: localhost
Port: 5432
Database: ucab_project
User: ucab
Password: ucab123
```

---

## 2. Arquitectura general

```
┌─────────────┐     ┌─────────────┐     ┌─────────────────────┐     ┌─────────────┐
│  Medidores  │────▶│    n8n      │────▶│  PostgreSQL (DWH)   │◀────│  Power BI   │
│  Smart Grid │     │  (Orquesta) │     │  ┌───────────────┐  │     │  (Visualiza)│
└─────────────┘     └─────────────┘     │  │   staging_    │  │     └─────────────┘
                                         │  │  eventos      │  │      
                                         │  │   telemetria  │  │      
                                         │  └───────┬───────┘  │      
                                         │          │          │      
                                         │     ┌────▼────┐     │      
                                         │     │  SP     │     │      
                                         │     │  ELT    │     │      
                                         │     └────┬────┘     │      
                                         │          │          │      
                                         │  ┌───────▼───────┐  │      
                                         │  │  fact_tables  │  │      
                                         │  │  dim_tables   │  │      
                                         │  └───────┬───────┘  │      
                                         │          │          │      
                                         │     ┌────▼────┐     │      
                                         │     │  vistas │     │      
                                         │     │ analít. │     │      
                                         │     └─────────┘     │      
                                         └─────────────────────┘      
```

### Estrategia ELT (no ETL)

La transformación ocurre **dentro de PostgreSQL**, no en n8n. Esto es deliberado:
PostgreSQL es un motor de conjuntos extremadamente eficiente; mover datos a n8n para
transformarlos y luego devolverlos sería un antipatrón de latencia y costo de red.

```
n8n      →  INSERT en staging_eventos / staging_telemetria   (E = Extract, L = Load)
PostgreSQL →  sp_reconciliar_* (T = Transform)
Power BI   →  SELECT sobre vistas analíticas                   (L = Load)
```

---

## 3. Modelo de datos

### Esquema star-like (constelación)

```
┌─────────────────────────────────────────────────────────────┐
│                     dim_tiempo                               │
│  (SK único por minuto, 2020-2030, llave de todas las facts)│
└─────────────────────────────────────────────────────────────┘

┌──────────────┐  ┌──────────────────┐  ┌─────────────────┐
│dim_geografia │  │ dim_red_electrica │  │dim_clientes_inv │
│  _urbana     │  │  (SCD Tipo 2)     │  │ (SCD Tipo 2)    │
└──────┬───────┘  └────────┬─────────┘  └────────┬────────┘
       │                   │                    │
       │     ┌─────────────┴───────────────┐    │
       │     │                           │    │
┌──────▼─────▼────────────────────────────▼────▼────────┐
│              fact_interrupciones                       │
│  sk_tiempo, sk_red, sk_geo, sk_clientes, sk_tipo_evento│
│  timestamp_inicio, timestamp_fin, duracion_minutos,     │
│  clientes_afectados, excluido_med                      │
└───────────────────────────────────────────────────────┘

┌──────────────┐  ┌──────────────────────────────────┐
│dim_tipo_evento│  │      fact_telemetria            │
│ (catálogo de  │  │  sk_tiempo, sk_red, sk_geo,       │
│  eventos)    │  │  timestamp_lectura, consumo_kwh,  │
└──────────────┘  │  voltaje                          │
                 └──────────────────────────────────┘
```

### Tablas staging (punto de entrada desde n8n)

- `staging_eventos` — eventos POWER_OUTAGE / POWER_RESTORATION
- `staging_telemetria` — lecturas horarias de consumo/voltaje

### Tablas de control y auditoría

- `ctrl_lotes_procesamiento` — tracking de ejecuciones SP
- `err_telemetria` — desvío de eventos corruptos/huérfanos

---

## 4. Archivos del proyecto

```
smart-city-sgbd/
├── 01-ddl-modelo-estrella.sql    ← Schema DDL completo (CREATE TABLE, INDEX, COMMENT)
├── 02-sp-reconciliacion-elt.sql  ← SP idempotentes + wrappers JSON para n8n
├── 03-vistas-analiticas.sql      ← 8+ vistas para Power BI
├── 04-datos-semilla.sql          ← Datos de prueba (generados por script Python)
├── 05-verificacion-smoke-test.sql← Protocolo de verificación post-deploy
├── generar_datos_semilla.py      ← Generador determinista de datos de prueba
├── docker-compose.yml            ← PostgreSQL 16 local
├── init-scripts/                 ← Scripts para inicialización automática del contenedor
├── openspec/                     ← SDD artifacts (spec, design, tasks)
└── proyecto.md                   ← Consignas originales del proyecto
```

---

## 5. Setup local

### 5.1 Levantar PostgreSQL con Docker

```bash
# Copiar variables de entorno
cp .env.example .env  # editar POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD

# Levantar contenedor (la primera vez inicializa la BD automáticamente)
docker-compose up -d

# Ver logs
docker-compose logs -f postgres
```

PostgreSQL queda disponible en `localhost:5432`.

### 5.2 Reset completo de la base (una línea)

Para partir de una base limpia y poblada con datos de prueba:

```bash
# Bash / Git Bash / WSL
bash scripts/reset-db.sh

# Windows PowerShell
.\scripts\reset-db.ps1
```

Esto: destruye el volumen → levanta postgres limpio → carga 01→02→03→04 → verifica row counts.

### 5.3 Cargar scripts en orden manualmente

```bash
psql -h localhost -U ucab -d ucab_project -f 01-ddl-modelo-estrella.sql
psql -h localhost -U ucab -d ucab_project -f 02-sp-reconciliacion-elt.sql
psql -h localhost -U ucab -d ucab_project -f 03-vistas-analiticas.sql
psql -h localhost -U ucab -d ucab_project -f 04-datos-semilla.sql
```

> **Nota:** El script 01 tarda ~30-60s por la carga de `dim_tiempo` (~5.8M filas).

### 5.4 Ejecutar smoke test

Después de cargar los 4 scripts, verificar que todo funciona:

```bash
psql -h localhost -U ucab -d ucab_project -f 05-verificacion-smoke-test.sql
```

Todas las secciones deben mostrar `✓ PASADA`. Si alguna falla, el mensaje indica exactamente cuál tabla o columna tiene el problema.

### 5.3 Regenerar datos de prueba

```bash
# Generar 60 días, 300 medidores, seed=42 (reproducible)
python generar_datos_semilla.py --days 60 --meters 300 --seed 42

# Luego recargar
psql -h localhost -U <user> -d <db> -f 04-datos-semilla.sql
```

---

## 7. Ejecutar los stored procedures

### Reconciliation de interrupciones

```sql
-- Procesar todos los eventos pendientes (sin filtro de fecha)
CALL sp_reconciliar_interrupciones();

-- Procesar rango específico (ej. última semana)
CALL sp_reconciliar_interrupciones(
    p_fecha_inicio => NOW() - INTERVAL '7 days',
    p_fecha_fin    => NOW()
);

-- Versión JSON (para invocar desde n8n o pg_cron)
SELECT * FROM fn_reconciliar_interrupciones(
    NOW() - INTERVAL '7 days',
    NOW()
);
```

### Reconciliation de telemetría

```sql
CALL sp_reconciliar_telemetria();
SELECT * FROM fn_reconciliar_telemetria(NULL, NULL);
```

### Marcar Major Event Days (MED) en fact_interrupciones

```sql
SELECT * FROM fn_actualizar_flag_med();
```

---

## 8. Integración con n8n

### Webhook para ingestar eventos desde medidores

```
n8n recibe HTTP POST de los medidores → insert en staging_eventos
```

```sql
-- Wrapper JSON que retorna resumen del lote (para监控)
SELECT * FROM fn_reconciliar_interrupciones(NULL, NULL);
```

### Programación horaria con pg_cron

```sql
-- Reconciliar interrupciones cada hora (últimas 25 horas)
SELECT cron.schedule(
    'reconciliacion-horaria',
    '0 * * * *',
    'CALL sp_reconciliar_interrupciones(
        NOW() - INTERVAL ''25 hours'',
        NOW() - INTERVAL ''1 hour''
    )'
);

-- Similar para telemetría (ejecutar 5 minutos después)
SELECT cron.schedule(
    'reconciliacion-telemetria-horaria',
    '5 * * * *',
    'CALL sp_reconciliar_telemetria(
        NOW() - INTERVAL ''25 hours'',
        NOW() - INTERVAL ''1 hour''
    )'
);
```

### Monitoreo de errores

```sql
-- Ver errores de ingestión en los últimos 7 días
SELECT * FROM vw_auditoria_errores
WHERE fecha >= NOW() - INTERVAL '7 days'
ORDER BY fecha DESC;

-- Ver salud del pipeline ELT
SELECT * FROM vw_monitoreo_elt
ORDER BY id_lote DESC
LIMIT 10;
```

---

## 9. Integración con Power BI

### Importar vistas (en este orden)

| Orden | Vista | Uso |
|-------|-------|-----|
| 1 | `vw_saidi_saifi_mensual` | Dashboard principal — KPIs, barras, drill-down |
| 2 | `vw_saidi_saifi_con_med` | Tabla de detalle con slicer MED |
| 3 | `vw_tendencia_12_meses` | Gráfico de línea — tendencia SAIDI |
| 4 | `vw_ranking_subestaciones` | Tabla de ranking con semáforo |
| 5 | `vw_heatmap_interrupciones` | Matrix visual — hora × día de semana |
| 6 | `vw_consumo_diario` | Consumo energético por geografía |
| 7 | `vw_voltaje_tendencia` | Monitoreo de calidad de voltaje |
| 8 | `vw_auditoria_errores` | Dashboard de calidad de datos |
| 9 | `vw_monitoreo_elt` | Dashboard operacional (equipo de datos) |

### Relaciones recomendadas

```
vw_saidi_saifi_mensual[periodo] ──────► vw_tendencia_12_meses[periodo]
vw_saidi_saifi_mensual[subestacion] ──► vw_ranking_subestaciones[subestacion]
```

### Medidas DAX recomendadas

```dax
// SAIDI YTD
SAIDI YTD = TOTALYTD([SAIDI], dim_tiempo[fecha])

// SAIFI YTD
SAIFI YTD = TOTALYTD([SAIFI], dim_tiempo[fecha])

// Variación interanual
% Variación IA = DIVIDE([SAIDI] - [SAIDI LY], [SAIDI LY])
```

### Conexión PostgreSQL en Power BI

1. **Get Data** → **PostgreSQL database**
2. Server: `localhost` (o IP del servidor)
3. Database: `smart_city_db` (o el nombre que configuraron)
4. Import mode (no DirectQuery, para aprovechar query folding)
5. Importar las 8 vistas listadas arriba

---

## 10. Pipeline de datos (flujo completo)

```
┌─────────────────────────────────────────────────────────────────┐
│                         MEDIDORES                               │
│  Envían eventos cada vez que detectan:                          │
│  - POWER_OUTAGE (caída)                                         │
│  - POWER_RESTORATION (restauración)                             │
│  - LECTURA_PERIODICA (consumo/voltaje cada hora)                │
└─────────────────────────┬───────────────────────────────────────┘
                          │ HTTP POST / MQTT
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                          n8n                                    │
│  - Recibe eventos de los medidores                              │
│  - Normaliza campos (timestamp, id_medidor, tipo_evento)        │
│  - INSERT en staging_eventos / staging_telemetria             │
│  - Scheduling: cada 1 hora ejecuta fn_reconciliar_interrupciones│
└─────────────────────────┬───────────────────────────────────────┘
                          │ SQL: INSERT + CALL
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    PostgreSQL (DWH)                             │
│                                                                  │
│  STAGING:  staging_eventos, staging_telemetria (CRUDO)         │
│                                                                  │
│  ELT:      sp_reconciliar_interrupciones()                      │
│            → Empareja OUTAGE→RESTORATION por medidor            │
│            → Aplica filtro IEEE 1366 (<5 min = transitorio)     │
│            → Desvía huérfanos a err_telemetria                 │
│            → Inserta en fact_interrupciones                    │
│                                                                  │
│            sp_reconciliar_telemetria()                          │
│            → Valida voltaje (0-1000V) y consumo (≥0)           │
│            → Convierte Wh→kWh                                   │
│            → Inserta en fact_telemetria                         │
│                                                                  │
│  ANALYTIC: 8+ vistas SQL para Power BI (SAIDI, SAIFI, etc.)    │
└─────────────────────────┬───────────────────────────────────────┘
                          │ SQL: SELECT
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Power BI                                  │
│  - Dashboard principal: SAIDI/SAIFI mensual con drill-down      │
│  - Gráfico de tendencia: últimos 24 meses                       │
│  - Heatmap: patrones horarios de interrupción                  │
│  - Ranking: subestaciones por desempeño                         │
│  - Auditoría: calidad de datos y salud del pipeline            │
└─────────────────────────────────────────────────────────────────┘
```

---

## 11. Indicadores clave (KPIs) y umbrales

| KPI | Descripción | Umbral/normal |
|-----|-------------|---------------|
| SAIDI | Minutos sin energía por cliente | < 60 min/mes = bueno |
| SAIFI | Interrupciones por cliente | < 2/mes = bueno |
| CAIDI | Duración promedio por corte | < 30 min = bueno |
| Tasa conversión | Hechos/staging | > 85% = saludable |
| Tasa errores | Huérfanos/staging | < 5% = saludable |

---

## 12. Convenciones de equipo

### Ramas y PRs

- Rama principal: `main` (siempre funcional)
- Features: `feat/nombre-descriptivo`
- PRs hacia `main`, mínimo 1 reviewer
- Mergear con **Squash and Merge** para mantener historial limpio

### Commits

```
feat(modelo): agregar dim_tipo_evento y sk_tipo_evento en fact_interrupciones
fix(sp): corregir buffer overflow en duración transitoria
docs(readme): agregar sección de integración n8n
```

### Stored procedures

- **Idempotentes**: ejecutar el SP 10 veces produce el mismo resultado que 1 vez
- Marcar `procesado = TRUE` al final, dentro de la misma transacción
- Si algo falla, todo hace `ROLLBACK`

---

## 13. Comandos útiles

```bash
# Ver logs del contenedor
docker-compose logs -f postgres

# Conectarse a PostgreSQL
psql -h localhost -U <user> -d <db>

# Ver tamaño de tablas
SELECT table_name, pg_size_pretty(pg_total_relation_size(quote_ident(table_name)))
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY pg_total_relation_size(quote_ident(table_name)) DESC;

# Ver eventos pendientes por procesar
SELECT COUNT(*) FROM staging_eventos WHERE procesado = FALSE;

# Ver último lote de procesamiento
SELECT * FROM ctrl_lotes_procesamiento ORDER BY id_lote DESC LIMIT 1;

# Regenerar datos semilla
python generar_datos_semilla.py --days 60 --meters 300 --seed 42
psql -h localhost -U <user> -d <db> -f 04-datos-semilla.sql
```

---

## 14. Glosario

| Término | Significado |
|---------|-------------|
| **SAIDI** | System Average Interruption Duration Index — minutos promedio sin energía por cliente |
| **SAIFI** | System Average Interruption Frequency Index — interrupciones promedio por cliente |
| **CAIDI** | Customer Average Interruption Duration Index — duración promedio por interrupción |
| **MED** | Major Event Day — día catastrófico que se excluye del SAIDI rutinario |
| **SCD Tipo 2** | Slowly Changing Dimension tipo 2 — versioning histórico de dimensiones |
| **ELT** | Extract, Load, Transform — cargar crudo y transformar en la BD |
| **SK** | Surrogate Key — llave artificial generada automáticamente |
| **BRIN** | Block Range Index — índice eficiente para datos secuenciales (timestamps) |