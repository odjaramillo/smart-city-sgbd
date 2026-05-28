# Design: Rediseño Completo de Arquitectura SGBD y Dashboard

## Technical Approach

Rewrite the four foundational layers (DDL, ELT SP, analytical views, dashboard) to fix 14 audit issues. The existing Kimball star topology is preserved but hardened with missing constraints, the ELT gains concurrency safety and fail-fast semantics, views adopt strict IEEE 1366 formulas, and the dashboard moves to module-level connection pooling with modern dbc components. All work is TDD-driven with pytest ≥80% coverage.

## Architecture Decisions

| Decision | Options | Tradeoff | Choice |
|----------|---------|----------|--------|
| Geography uniqueness | No constraint vs UNIQUE(sector_urbano) | Duplicates vs insert rigidity | **UNIQUE(sector_urbano)** — specs require deterministic 1:N mapping |
| SCD2 on dim_red_electrica | SCD Type 1 (overwrite) vs Type 2 | Loses history vs more rows | **SCD Type 2** — facts must reference topology at event time |
| dim_tiempo granularity | Day vs Minute | Storage (365 vs 5.7M rows) vs IEEE 1366 minute precision | **Day-level** with `timestamp_completo DATE` — facts store timestamps directly; dim_tiempo provides hierarchy rollups only |
| BRIN vs B-tree on facts | B-tree on all SKs vs BRIN on timestamps | 400MB vs 100KB; JOIN speed | **BRIN on timestamps, B-tree only on sk_tiempo** — existing pattern is correct, preserved |
| ELT concurrency | No lock vs `FOR UPDATE SKIP LOCKED` | Duplicate processing vs slight overhead | **FOR UPDATE SKIP LOCKED** — spec requirement for parallel safety |
| Cross-batch pairing | Date-filtered staging vs full unprocessed scan | Misses cross-batch events vs scans more rows | **Full unprocessed scan** (no date filter on staging WHERE) — pairs events across batch boundaries |
| Sequence handling | `currval` assumption vs `RETURNING` | Session fragility vs explicit | **RETURNING clause** on every INSERT — spec requirement |
| Fail-fast vs quarantine | Silent fallback (create "DESCONOCIDO" dims) vs RAISE EXCEPTION | Corrupts data vs blocks batch | **RAISE EXCEPTION** for missing dims; quarantine only for orphan events — spec requirement |
| SAIFI formula | COUNT(events) vs SUM(clientes_afectados) | Undercounts vs IEEE compliant | **SUM(clientes_afectados) / total_clientes_servidos** — IEEE 1366 |
| Dashboard engine | Per-callback `create_engine()` vs module-level singleton | Connection leak vs reuse | **Module-level `_engine`** with `pool_pre_ping=True` — spec requirement |
| dbc components | `dbc.FormGroup` vs `dbc.Row`+`dbc.Col` | Deprecated vs modern | **`dbc.Row`/`dbc.Col`** — dbc ≥1.5.0 drops FormGroup |
| Error handling in callbacks | Silent `except Exception` vs log+propagate | Hidden bugs vs visible errors | **`logging.exception()` + error state to UI** — spec requirement |
| Docker volume mount | `./dashboard:/app` vs `./dashboard:/app/dashboard` | Masks generated assets vs safe | **`./dashboard:/app/dashboard`** — preserves `/app` structure |

## Data Flow

### ELT Pipeline (staging → dimensions → facts)

```
n8n ──INSERT──→ staging_eventos (procesado=FALSE)
                      │
                      ▼
        sp_reconciliar_interrupciones()
                      │
         ┌────────────┼────────────┐
         ▼            ▼            ▼
   [FOR UPDATE   [Pair OUTAGE  [SK Lookup
   SKIP LOCKED]   →RESTORATION]  via RETURNING]
         │            │            │
         ▼            ▼            ▼
   Mark processed  Insert fact   Resolve dims
   in staging      or quarantine (fail-fast)
                      │
                      ▼
              ctrl_lotes_procesamiento
```

### Cross-Batch Event Pairing

```
Batch A:  OUTAGE(med=1, ts=10:00)  → procesado=FALSE (no pair yet)
Batch B:  RESTORATION(med=1, ts=11:30) arrives

Batch B SP:
  1. SELECT FROM staging WHERE procesado=FALSE  ← includes Batch A's OUTAGE
  2. Window: LAG/LEAD over (PARTITION BY medidor ORDER BY ts)
  3. Pairs: OUTAGE(10:00) → RESTORATION(11:30) = 90 min
  4. INSERT INTO fact_interrupciones ... RETURNING sk_interrupcion
  5. UPDATE staging SET procesado=TRUE WHERE id_evento IN (outage_id, rest_id)
```

### Dashboard Data Flow

```
PostgreSQL Views ──SQL──→ queries.py (module-level engine)
                              │
                         pd.read_sql()
                              │
                              ▼
                    Dash Callbacks (logging)
                              │
                    ┌─────────┼─────────┐
                    ▼         ▼         ▼
              KPI Cards   Charts    Drill-down Table
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `01-ddl-modelo-estrella.sql` | **Rewrite** | Add UNIQUE constraints, fix dim_tiempo to day-level, add CHECK on dim_clientes_inventario, add FK indexes |
| `02-sp-reconciliacion-elt.sql` | **Rewrite** | FOR UPDATE SKIP LOCKED, RETURNING, fail-fast on missing dims, cross-batch pairing without date filter |
| `03-vistas-analiticas.sql` | **Rewrite** | Fix SAIFI formula, native INTERVAL math, correct MED log transform, granularity-safe GROUPING SETS |
| `04-datos-semilla.sql` | **Modify** | Adapt seed data to new DDL constraints |
| `05-verificacion-smoke-test.sql` | **Modify** | Update expected counts for new formulas |
| `dashboard/data/queries.py` | **Rewrite** | Module-level `_engine`, connection reuse, `.fillna()` |
| `dashboard/callbacks.py` | **Rewrite** | `logging.exception()`, error propagation, `.fillna()` instead of `.fill()` |
| `dashboard/components/filters.py` | **Rewrite** | Replace `dbc.FormGroup` with `dbc.Row`/`dbc.Col`, dynamic DB-populated options |
| `dashboard/layouts/drilldown.py` | **Modify** | Replace deprecated components, null-safe breadcrumb |
| `dashboard/app.py` | **Modify** | Remove duplicate cache init, fix layout for new components |
| `docker-compose.yml` | **Modify** | Fix volume mount to `./dashboard:/app/dashboard` |
| `Dockerfile` | **Modify** | Copy full project (not just dashboard/) for tests access |
| `tests/conftest.py` | **Rewrite** | Add DB fixtures (testcontainers or test DB), engine fixture |
| `tests/unit/test_queries.py` | **Create** | Unit tests for query builders with mocked engine |
| `tests/unit/test_callbacks.py` | **Create** | Unit tests for callback logic with mocked queries |
| `tests/unit/test_filters.py` | **Create** | Unit tests for filter component rendering |
| `tests/integration/test_views.py` | **Create** | Integration tests against real PG views (SAIDI/SAIFI correctness) |
| `tests/integration/test_elt.py` | **Create** | Integration tests for SP: idempotency, concurrency, cross-batch |

## Interfaces / Contracts

### Key DDL Constraints (new)

```sql
-- dim_geografia_urbana: deterministic mapping
ALTER TABLE dim_geografia_urbana
  ADD CONSTRAINT uq_sector UNIQUE (sector_urbano);

-- dim_red_electrica: SCD2 uniqueness per meter per time range
ALTER TABLE dim_red_electrica
  ADD CONSTRAINT uq_medidor_scd2
  UNIQUE (id_medidor_origen, fecha_inicio);

-- fact_interrupciones: prevent duplicate facts
ALTER TABLE fact_interrupciones
  ADD CONSTRAINT uq_fact_medidor_inicio
  UNIQUE (id_medidor, timestamp_inicio);
```

### Module-Level Engine Pattern

```python
# dashboard/data/queries.py
_engine: Engine | None = None

def get_engine() -> Engine:
    global _engine
    if _engine is None:
        _engine = create_engine(os.getenv("DATABASE_URL"),
                                pool_size=5, max_overflow=10,
                                pool_pre_ping=True)
    return _engine
```

### IEEE 1366 SAIFI Formula (corrected)

```sql
-- SAIFI = Σ(clientes_afectados) / total_clientes_servidos
SUM(fi.clientes_afectados)::NUMERIC
  / NULLIF(MAX(ci.total_clientes_servidos), 0)
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Unit | Query builder SQL generation, callback aggregation logic, component rendering | Mock engine, assert SQL strings, assert component structure |
| Integration | SAIDI/SAIFI correctness, ELT idempotency, cross-batch pairing, FK violations, concurrency | Real PG via `testcontainers` or Docker test DB; seed → run SP → assert views |
| E2E | Dashboard loads, filters populate, drill-down navigates | Not in scope (no browser runner); manual smoke test via `05-verificacion-smoke-test.sql` |

## Migration / Rollout

No migration required — this is a foundational rewrite on a development branch. The rollback plan is to discard the branch. For production deployment: `DROP` all views → `DROP` all tables → re-execute DDL scripts in order (01→02→03→04).

## Open Questions

- [ ] Should `dim_tiempo` keep minute granularity (existing) or switch to day-level? Day-level reduces 5.7M rows to ~3,650 but requires facts to store raw timestamps for minute-precision duration math. **Recommendation: day-level** — duration is computed from `timestamp_fin - timestamp_inicio` (INTERVAL), not from dim_tiempo.
- [ ] Testcontainers for Python integration tests vs shared Docker PG? Testcontainers is cleaner but adds a dependency. **Recommendation: testcontainers-postgres** for isolation.
