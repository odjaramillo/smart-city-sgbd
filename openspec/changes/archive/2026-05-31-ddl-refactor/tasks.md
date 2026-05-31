# Tasks: Refactorización Arquitectónica del DDL

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~980 |
| Session review budget | 800 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 DDL → PR2 seeds/generator → PR3 SPs → PR4 views/smoke |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema contracts and dependencies | PR 1 | base = feature/tracker branch |
| 2 | Seeds and generator sync | PR 2 | base = PR 1 branch |
| 3 | ELT procedures | PR 3 | base = PR 2 branch |
| 4 | Views and smoke verification | PR 4 | base = PR 3 branch |

## Phase 1: Foundation

- [x] 1.1 Add `dim_tipo_evento` DDL to `01-ddl-modelo-estrella.sql`. Deps: none. AC: REQ-3 columns/indexes match design and support manual `-1` seed. Est: 140 LOC.
- [x] 1.2 Add `staging_telemetria` and `fact_telemetria` to `01-ddl-modelo-estrella.sql`. Deps: 1.1. AC: REQ-1/2 compile with hourly UNIQUE, BRIN, FK, and processing indexes. Est: 170 LOC.
- [x] 1.3 Update `fact_interrupciones`, `staging_eventos`, and `err_telemetria` in `01-ddl-modelo-estrella.sql`. Deps: 1.1. AC: REQ-4/5/6 add `sk_tipo_evento`, expanded CHECK, `tipo_error`, and indexes. Est: 100 LOC.

## Phase 2: Seed and ELT

- [x] 2.1 Seed `dim_tipo_evento` (`-1` + catalog) and sample `staging_telemetria` in `04-datos-semilla.sql`; sync `generar_datos_semilla.py`. Deps: 1.1-1.3. AC: dimension-first load order and valid telemetry inserts from generator. Est: 130 LOC.
- [x] 2.2 Add `sp_reconciliar_telemetria()` and `fn_reconciliar_telemetria()` in `02-sp-reconciliacion-elt.sql`. Deps: 1.2, 2.1. AC: Scenarios 1.1/1.3/1.4 resolve SKs, convert Wh→kWh, log warnings, stay idempotent. Est: 170 LOC.
- [x] 2.3 Update `sp_reconciliar_interrupciones()` in `02-sp-reconciliacion-elt.sql` for `sk_tipo_evento` lookup and `EVENTO_DESCONOCIDO` logging. Deps: 1.1, 1.3, 2.1. AC: Scenarios 4.1/4.2 insert known types and fallback to `-1` without breaking pairing. Est: 80 LOC.

## Phase 3: Analytics

- [x] 3.1 Add `vw_consumo_diario` and `vw_voltaje_tendencia` in `03-vistas-analiticas.sql`. Deps: 1.2, 2.2. AC: telemetry views aggregate `fact_telemetria` at the designed grain for Power BI. Est: 65 LOC.
- [x] 3.2 Update `vw_saidi_saifi_diario` in `03-vistas-analiticas.sql` to JOIN `dim_tipo_evento`. Deps: 1.1, 1.3, 2.3. AC: Scenario 3.4 exposes `categoria`, `severidad`, and `es_critico`; derived views still compile. Est: 35 LOC.

## Phase 4: Verification

- [x] 4.1 Extend `05-verificacion-smoke-test.sql` for new schema checks, `dim_tipo_evento = -1`, telemetry SP run/idempotency, and analytics view assertions. Deps: 2.1-3.2. AC: smoke covers REQ-1..6, unknown-event fallback, and non-empty telemetry views. Est: 90 LOC.
