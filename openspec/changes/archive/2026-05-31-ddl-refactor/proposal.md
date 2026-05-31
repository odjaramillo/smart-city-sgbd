# Proposal: Refactorización Arquitectónica del DDL

**Change**: ddl-refactor
**Date**: 2026-05-31
**Status**: PROPOSED

## Intent

Refactorizar el modelo dimensional del Data Mart Smart City para cumplir con los requisitos del enunciado del proyecto (mediciones de consumo, fluctuaciones y tiempos de caída) y habilitar el Stress Test (cambio de reglas de negocio en vivo sin reconstrucción total).

**Problema actual**: El DDL existente solo captura interrupciones (fact_interrupciones), no tiene dimensión de tipo de evento, y no puede reportar consumo ni fluctuaciones de voltaje. Esto viola el requisito explícito del profesor y hace imposible pasar el Stress Test.

**Solución**: Arquitectura de dos tablas de hechos (fact_telemetria + fact_interrupciones) + nueva dimensión dim_tipo_evento, manteniendo el modelo Kimball estrella y SCD2 para activos críticos.

## Scope

### In Scope ✅

1. **Reescritura completa de `01-ddl-modelo-estrella.sql`** (clean slate):
   - Nueva tabla: `fact_telemetria` (periodic snapshot: consumo_kwh, voltaje)
   - Nueva tabla: `dim_tipo_evento` (codigo_evento, categoria, severidad, es_critico, regla_vigencia_desde/hasta)
   - Nueva tabla: `staging_telemetria` (landing zone para lecturas periódicas)
   - Actualización: `fact_interrupciones` (agregar FK a dim_tipo_evento)
   - Actualización: `staging_eventos` (expandir CHECK constraint para soportar más tipos de evento)
   - Mantener: dim_tiempo, dim_geografia_urbana, dim_red_electrica, dim_clientes_inventario, err_telemetria, ctrl_lotes_procesamiento

2. **Actualización de `02-sp-reconciliacion-elt.sql`**:
   - Nuevo SP: `sp_reconciliar_telemetria()` (set-based bulk INSERT, sin cursor)
   - Actualización: `sp_reconciliar_interrupciones()` (resolver sk_tipo_evento via lookup)

3. **Actualización de `03-vistas-analiticas.sql`**:
   - Nuevas vistas: `vw_consumo_diario`, `vw_voltaje_tendencia`
   - Actualización: vistas SAIDI/SAIFI (JOIN dim_tipo_evento para filtrado por severidad)

4. **Actualización de `04-datos-semilla.sql`**:
   - Seed data para dim_tipo_evento (catálogo de eventos con fila -1 Unknown)
   - Seed data para staging_telemetria (lecturas periódicas de ejemplo)

5. **Actualización de `05-verificacion-smoke-test.sql`**:
   - Checks de integridad para nuevas tablas
   - Validación de SPs actualizados
   - Verificación de fila -1 en dim_tipo_evento

6. **Actualización de `generar_datos_semilla.py`**:
   - Agregar dim_tipo_evento a target_tables
   - Lógica de generación para staging_telemetria

### Out of Scope ❌

- Migración de datos existentes (no hay datos en producción)
- Optimización de rendimiento avanzada (particionamiento, índices especializados)
- Integración con Power BI (solo se proveen las vistas, no el modelo semántico en Power BI)
- Cambios a la lógica de MED day exclusion (se mantiene idéntica)
- Implementación de n8n workflows (solo se definen los contratos de staging)

## Approach

### Estrategia de Refactorización

**Opción elegida**: Reescritura completa de `01-ddl-modelo-estrella.sql` desde cero (clean slate).

**Razones**:
1. No existen datos en producción que requieran migración
2. El generador Python auto-adapta (parsea el DDL para extraer columnas insertables)
3. Historia coherente para defensa académica ("diseñamos este schema" vs "evolucionamos este schema")
4. Flexibilidad para Stress Test (schema limpio y minimal)

**Para SPs y vistas**: Actualización incremental (no reescritura completa), ya que la lógica existente para interrupciones es mayormente correcta.

### Arquitectura de Dos Fact Tables

**fact_telemetria** (Periodic Snapshot):
- **Grano**: Una lectura por medidor por intervalo de tiempo (granularidad a definir en fase de diseño)
- **Métricas**: consumo_kwh, voltaje
- **Relaciones**: dim_tiempo, dim_red_electrica, dim_geografia_urbana, dim_tipo_evento
- **Uso**: Análisis de consumo, detección de fluctuaciones, tendencias de voltaje

**fact_interrupciones** (Accumulating Snapshot):
- **Grano**: Un par OUTAGE→RESTORATION por evento de interrupción
- **Métricas**: duracion_minutos, clientes_afectados
- **Relaciones**: dim_tiempo (inicio), dim_tiempo (fin), dim_red_electrica, dim_geografia_urbana, dim_tipo_evento, dim_clientes_inventario
- **Uso**: Cálculo de SAIDI, SAIFI, CAIDI

**Beneficios de separar**:
- Respeto a la regla de oro de Kimball: grano uniforme por fact table
- Agregaciones limpias en Power BI (sin filtros complejos ni ambigüedad semántica)
- SAIDI/SAIFI se calcula exclusivamente desde fact_interrupciones (sin ruido)

### dim_tipo_evento (Nueva Dimensión)

**Propósito**: Aislar reglas de negocio del schema físico para habilitar Stress Test.

**Estructura**:
- `sk_tipo_evento BIGINT IDENTITY PRIMARY KEY`
- `codigo_evento VARCHAR(50) UNIQUE NOT NULL` (ej: 'POWER_OUTAGE', 'VOLTAGE_SPIKE', 'HEARTBEAT')
- `categoria VARCHAR(30)` (ej: 'INTERRUPCION', 'FLUCTUACION', 'TELEMETRIA')
- `severidad VARCHAR(20)` (ej: 'BAJA', 'MEDIA', 'ALTA', 'CRITICA')
- `es_critico BOOLEAN DEFAULT FALSE`
- `descripcion TEXT`
- `regla_vigencia_desde TIMESTAMPTZ`
- `regla_vigencia_hasta TIMESTAMPTZ`

**Fila obligatoria**: -1 (Desconocido/Unknown) para integridad referencial cuando el tipo de evento no se reconoce.

**Caso de uso en Stress Test**: Si el profesor pide redefinir "Pico Crítico" durante la defensa:
```sql
UPDATE dim_tipo_evento 
SET severidad = 'CRITICA', es_critico = TRUE 
WHERE codigo_evento = 'VOLTAGE_SPIKE';
```
Power BI refleja el cambio instantáneamente sin reprocesar datos históricos (las FKs apuntan a la misma dimensión actualizada).

### Staging Tipado (Sin JSONB, Sin ENUMs)

**Decisión**: Columnas tipadas con VARCHAR y CHECK constraints evolutivas.

**Razones**:
- Validación temprana en insert (n8n recibe error inmediato si el payload no cumple schema)
- Debugging más simple a escala académica (cientos/miles de eventos, no millones)
- Sin ENUMs rígidos: usar `VARCHAR(50) CHECK (tipo_evento IN (...))` permite agregar valores con ALTER TABLE simple
- Dos tablas de staging separadas (staging_eventos para interrupciones, staging_telemetria para lecturas periódicas) para mantener contrato de datos limpio

### Dos Pipelines ELT

**Pipeline 1: Interrupciones** (existente, actualizado):
1. n8n ingiere eventos POWER_OUTAGE/POWER_RESTORATION → staging_eventos
2. SP `sp_reconciliar_interrupciones()` correlaciona pares con Window Functions (LAG)
3. INSERT INTO fact_interrupciones con sk_tipo_evento resuelto via lookup

**Pipeline 2: Telemetría** (nuevo):
1. n8n ingiere lecturas periódicas → staging_telemetria
2. SP `sp_reconciliar_telemetria()` hace set-based bulk INSERT (sin cursor, más simple)
3. INSERT INTO fact_telemetria con conversión de unidades y resolución de SKs

**n8n necesita**: Dos workflow branches (o un conditional router) para enrutar a la tabla de staging correcta.

## Risks

### 1. Volumen de Datos en fact_telemetria ⚠️ (CRÍTICO)

**Problema**: Granularidad por minuto × 300 medidores × 10 años = **1.5 billones de filas**. Supabase PostgreSQL no puede manejar esto eficientemente.

**Opciones de mitigación** (a decidir en fase de diseño):
- (a) Cada 15 minutos → ~100M filas (manejable con índices BRIN)
- (b) Cada hora → ~26M filas (cómodo, pero pierde resolución)
- (c) Solo durante eventos de interrupción → volumen bajo pero pierde contexto de consumo

**Impacto**: Si no se mitiga, el proyecto falla en producción.

### 2. Complejidad de Power BI con Dos Fact Tables

**Problema**: Power BI necesita importar dos tablas de hechos y crear relaciones DAX via dim_tiempo para análisis combinados.

**Mitigación**: 
- Vistas agregadas (`vw_consumo_diario`, `vw_voltaje_tendencia`) para reducir volumen de import
- Relaciones implícitas via dim_tiempo (patrón estándar en Power BI)
- Documentar que telemetría de alta granularidad puede requerir DirectQuery mode (no import)

### 3. Dos ETL Pipelines en n8n

**Problema**: n8n debe enrutar a dos tablas de staging diferentes según el tipo de payload.

**Mitigación**:
- Conditional router en n8n workflow basado en estructura del payload
- Dos SPs separados (más simple que uno monolítico)
- Documentar contratos de staging claramente

### 4. Bootstrapping de dim_tipo_evento

**Problema**: La fila -1 (Unknown) debe existir antes de cargar cualquier dato de hechos.

**Mitigación**:
- Incluir INSERT de fila -1 en 04-datos-semilla.sql
- Documentar orden de ejecución: dimensiones primero, luego staging, luego SPs
- Smoke test debe verificar existencia de fila -1 antes de ejecutar SPs

### 5. Dead Letter Queue para Telemetría

**Problema**: err_telemetria actual es específica de interrupciones (id_evento_origen, RESTAURACION_HUERFANA). Telemetría tiene diferentes tipos de errores.

**Opciones** (a decidir en fase de diseño):
- Extender err_telemetria con columna tipo_error (discriminador)
- Tabla separada err_telemetria_lecturas
- Mantener err_telemetria genérica con JSONB para detalles técnicos

## Open Questions (Defer to Design Phase)

1. **Granularidad de fact_telemetria**: ¿Cada 15 minutos, cada hora, o solo durante eventos?
2. **Arquitectura de staging**: ¿Dos tablas separadas (staging_eventos + staging_telemetria) o una unificada con columnas nullable?
3. **Estrategia de DLQ**: ¿Extender err_telemetria o tabla separada para errores de telemetría?
4. **Índices para fact_telemetria**: ¿BRIN sobre timestamp_lectura es suficiente, o necesitamos B-Tree adicionales?
5. **Conversión de unidades**: ¿Las lecturas de telemetría vienen en kWh o Wh? ¿Voltaje en V o kV? ¿El SP hace conversión?

## Next Steps

1. **Spec Phase**: Definir requisitos detallados para cada tabla nueva/actualizada
2. **Design Phase**: Resolver open questions (granularidad, staging, DLQ), diseñar estructura SQL detallada
3. **Tasks Phase**: Descomponer en tareas implementables
4. **Apply Phase**: Implementar DDL, SPs, vistas, seed data, smoke test
5. **Verify Phase**: Validar integridad referencial, ejecución de SPs, resultados de smoke test
6. **Archive Phase**: Cerrar cambio y persistir estado final

## Artifacts

- **Engram**: `sdd/ddl-refactor/proposal` (pending save)
- **OpenSpec**: `openspec/ddl-refactor/proposal.md` (this file)

---

**Proposed by**: SDD Orchestrator
**Approved by**: Pending user confirmation
