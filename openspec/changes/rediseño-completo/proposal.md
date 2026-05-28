# Proposal: Rediseño Completo de Arquitectura SGBD y Dashboard

## Intent

Reconstruir desde cero el modelo dimensional, la capa ELT, las vistas analíticas y el dashboard del proyecto para resolver 14 problemas críticos detectados en auditoría. El objetivo es garantizar el cumplimiento del estándar IEEE 1366 (SAIDI/SAIFI), la concurrencia segura y una UI robusta y moderna, eliminando las falacias analíticas y bugs fundacionales actuales.

## Scope

### In Scope
- Modelo dimensional Kimball completo con granularidad correcta (verdadera relación medidor-geografía, jerarquía de tiempo, SCD Tipo 2).
- Capa ELT robusta e idempotente (Stored Procedures, manejo seguro de secuencias, control de concurrencia `FOR UPDATE SKIP LOCKED`).
- Vistas analíticas corregidas para el cálculo estricto de SAIDI/SAIFI según IEEE 1366.
- Dashboard profesional con Dash 2.x y `dash-bootstrap-components` >= 1.5.0, con manejo eficiente de conexiones (SQLAlchemy module-level) y manejo de errores.
- Pruebas de humo (smoke tests) que validen las vistas consumidas por el dashboard y datos semilla realistas.

### Out of Scope
- Conector para Power BI en esta iteración.
- Integración de streaming en tiempo real.

## Capabilities

> This section is the CONTRACT between proposal and specs phases.

### New Capabilities
- `dimensional-model`: Esquema estrella Kimball (dim_tiempo, dim_geografia_urbana) asegurando la atomicidad.
- `elt-pipeline`: Pipeline ELT transaccional, con fail-fast y pareo cross-batch de eventos.
- `analytical-views`: Cálculos de indicadores de resiliencia (SAIDI, SAIFI, exclusión MED).
- `dashboard-ui`: Frontend en Dash con drill-down interactivo y filtros poblados dinámicamente.

### Modified Capabilities
- None

## Approach

Implementaremos una arquitectura robusta apoyada en PostgreSQL 16 y Python 3.11+. La persistencia adoptará un modelo de estrella con restricciones duras (FK, CHECK, UNIQUE). En la capa ELT, eliminaremos fallbacks silenciosos que corrompen datos y adoptaremos transacciones seguras. Analíticamente, usaremos matemáticas de fechas con `INTERVAL` y aislamientos de granularidad para evitar conteos duplicados. El dashboard mantendrá una única conexión a la base de datos (connection pool en módulo), reemplazará componentes obsoletos y gestionará fallos explícitamente (`.fillna()`). Todo el desarrollo estará dirigido por pruebas (TDD) en ciclo Red-Green-Refactor usando `pytest`.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `database/schema/` | New/Modified | Reescritura del modelo estrella y constraints. |
| `database/elt/` | New/Modified | Stored procedures transaccionales reescritos. |
| `database/views/` | New/Modified | Vistas analíticas refactorizadas. |
| `dashboard/` | Modified | Refactorización de componentes, callbacks y conexión. |
| `docker-compose.yml` | Modified | Corrección de volúmenes compartidos y permisos. |
| `tests/` | New | Suite TDD de vistas y dashboard con cobertura >=80%. |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Concurrencia de ELT y Secuencias | Med | Uso estricto de `RETURNING` y `FOR UPDATE SKIP LOCKED` en inserciones. |
| Corrupción matemática de fechas | Low | Reemplazo de aritmética de enteros por operadores `INTERVAL` nativos de PG. |
| Incompatibilidad de paquetes Dash | Low | Pin exacto de `dash-bootstrap-components` y tests tempranos de renderizado. |

## Rollback Plan

Dado que es una reescritura fundacional desde cero en lugar de un parche, el rollback consiste en descartar la rama de trabajo y restaurar el commit de base anterior al inicio del rediseño. Si se implementa en producción, requerirá un script de teardown para las vistas y tablas reconstruidas para regresar a los esquemas legacy.

## Dependencies

- Dash 2.x, `dash-bootstrap-components` 1.5.0+, SQLAlchemy.
- PostgreSQL 16 local o en Docker.

## Success Criteria

- [ ] Todas las pruebas automatizadas (pytest) pasan con cobertura >= 80%.
- [ ] SAIDI y SAIFI se calculan con el divisor `total_clientes_servidos` según IEEE 1366.
- [ ] Ejecuciones concurrentes del proceso ELT no generan duplicados.
- [ ] Dashboard levanta correctamente en Docker (sin errores de mount ni dependencias rotas).
- [ ] Los filtros del dashboard (sector, fecha) interactúan correctamente y poblados desde BD.
