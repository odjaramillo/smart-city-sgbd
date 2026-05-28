# Tasks: Rediseño Completo — SGBD y Dashboard

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 1,800–2,400 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 |
| Delivery strategy | auto-forecast |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | DB Schema & Seeds | PR 1 | Base = main; DDL + seeds + smoke test updates |
| 2 | ELT Stored Procedures | PR 2 | Base = main (stacked); SP rewrite + integration tests |
| 3 | Analytical Views | PR 3 | Base = main (stacked); views rewrite + IEEE 1366 validation |
| 4 | Dashboard UI | PR 4 | Base = main (stacked); component rewrite + unit/integration tests |

---

## Phase 1: DB Schema & Seeds

- [ ] 1.1 Rewrite `01-ddl-modelo-estrella.sql`: add UNIQUE constraint on `dim_geografia_urbana(sector_urbano)`, add `uq_medidor_scd2` on `dim_red_electrica(id_medidor_origen, fecha_inicio)`, add `uq_fact_medidor_inicio` on `fact_interrupciones(id_medidor, timestamp_inicio)`, add CHECK constraints, add FK indexes. Drop and recreate all tables cleanly.
- [ ] 1.2 Rewrite `04-datos-semilla.sql`: align seed data with new DDL constraints (UNIQUE sectors, SCD2 validity ranges). Ensure `total_clientes_servidos > 0` for SAIDI/SAIFI denominator.
- [ ] 1.3 Rewrite `05-verificacion-smoke-test.sql`: update expected row counts and FK integrity assertions for new constraint model.
- [ ] 1.4 TDD — Write `tests/unit/test_ddl_constraints.py`: RED — write tests that assert UNIQUE/FK/CHECK constraints fail on invalid data. GREEN — confirm DDL applied correctly. REFACTOR — simplify constraint names.

---

## Phase 2: ELT Stored Procedures

- [ ] 2.1 Rewrite `02-sp-reconciliacion-elt.sql`: implement `FOR UPDATE SKIP LOCKED` on staging fetch, use `RETURNING` on every INSERT, fail-fast RAISE EXCEPTION for missing dims, full unprocessed scan for cross-batch pairing (no date filter on staging WHERE).
- [ ] 2.2 TDD — Write `tests/integration/test_elt_concurrency.py`: RED — write test that runs two ELT SP instances concurrently and asserts no duplicate processing. GREEN — confirm `SKIP LOCKED` prevents duplicates. REFACTOR — add idempotency assertions.
- [ ] 2.3 TDD — Write `tests/integration/test_elt_cross_batch.py`: RED — write test that simulates Batch A OUTAGE + Batch B RESTORATION, assert 90-min duration in fact table. GREEN — confirm cross-batch pairing works. REFACTOR — add multiple meter pairing.
- [ ] 2.4 TDD — Write `tests/integration/test_elt_fail_fast.py`: RED — write test that inserts event with impossible state transition, assert RAISE EXCEPTION and rollback. GREEN — confirm fail-fast semantics. REFACTOR — add quarantine path test.

---

## Phase 3: Analytical Views

- [ ] 3.1 Rewrite `03-vistas-analiticas.sql`: fix SAIFI formula to `SUM(clientes_afectados) / total_clientes_servidos` (IEEE 1366), replace integer date arithmetic with native `INTERVAL` types, implement correct MED log-transform threshold, use GROUPING SETS for granularity-safe aggregation.
- [ ] 3.2 TDD — Write `tests/integration/test_views_saidi_saifi.py`: RED — write tests asserting SAIDI uses `sum(duracion_minutos) / total_clientes_servidos` and SAIFI uses `sum(clientes_afectados) / total_clientes_servidos`. GREEN — confirm correct formulas. REFACTOR — add MED exclusion toggle test.
- [ ] 3.3 TDD — Write `tests/integration/test_views_granularity.py`: RED — write test that queries Substation-level metrics and asserts no Cartesian duplicates from Transformer-level. GREEN — confirm explicit GROUP BY at correct level. REFACTOR — add hierarchical drill-down aggregation test.

---

## Phase 4: Dashboard UI

- [ ] 4.1 Rewrite `dashboard/data/queries.py`: replace per-call `get_engine()` with module-level singleton `_engine` (lazy init, `pool_pre_ping=True`), replace all `.fill()` with `.fillna()`, remove `load_dotenv()` (env vars injected by Docker).
- [ ] 4.2 TDD — Write `tests/unit/test_queries.py`: RED — write tests asserting module-level engine is reused across calls (not recreated). GREEN — confirm singleton pattern. REFACTOR — add connection pool parameter tests.
- [ ] 4.3 Rewrite `dashboard/callbacks.py`: replace all `except Exception` with `logging.exception()` + error state propagation to UI, replace `.fill()` with `.fillna()`.
- [ ] 4.4 TDD — Write `tests/unit/test_callbacks.py`: RED — write tests that simulate callback exceptions and assert logging + error UI state. GREEN — confirm `logging.exception()` called. REFACTOR — add error state render test.
- [ ] 4.5 Rewrite `dashboard/components/filters.py`: replace deprecated `dbc.FormGroup` with `dbc.Row`/`dbc.Col`, populate dropdowns dynamically from dimension tables (`get_distinct_sectors()`, `get_distinct_criticality()`, etc.).
- [ ] 4.6 TDD — Write `tests/unit/test_filters.py`: RED — write tests asserting dbc.Row/Col structure and that options come from DB queries. GREEN — confirm modern component usage. REFACTOR — add filter interaction test.
- [ ] 4.7 Rewrite `dashboard/layouts/drilldown.py`: replace deprecated components, add null-safe breadcrumb navigation.
- [ ] 4.8 Modify `dashboard/app.py`: remove duplicate cache init, fix layout for new components.
- [ ] 4.9 Modify `docker-compose.yml`: fix volume mount to `./dashboard:/app/dashboard` (preserves `/app` structure).
- [ ] 4.10 Modify `Dockerfile`: ensure full project copied for test access.
- [ ] 4.11 Rewrite `tests/conftest.py`: add DB fixtures (testcontainers or test DB), engine fixture with module-level singleton for tests.

---

## Phase 5: Integration & Smoke

- [ ] 5.1 Integration — run full `05-verificacion-smoke-test.sql` against new schema and assert all checks pass.
- [ ] 5.2 Verify — confirm pytest unit tests pass with >=80% coverage (`pytest --cov= dashboard tests/ --cov-fail-under=80`).
- [ ] 5.3 Verify — confirm Docker Compose build succeeds without mount errors.