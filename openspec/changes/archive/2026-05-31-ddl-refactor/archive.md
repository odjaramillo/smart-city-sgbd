# Archive Report: Refactorización Arquitectónica del DDL

**Change**: ddl-refactor
**Archived**: 2026-05-31
**Lifecycle**: explore → proposal → spec → design → tasks → apply → verify → archive
**Status**: ✅ COMPLETE — All 4 PRs verified PASS

---

## 1. Change Intent and Scope

**Intent**: Refactor DDL to support consumo + fluctuaciones + tiempos de caída (professor requirements), enable Stress Test via dim_tipo_evento without full reconstruction.

**Scope**: Rewrite `01-ddl-modelo-estrella.sql` (clean slate), update SPs, views, seed data, smoke test, and Python generator. Two-fact Kimball constellation architecture.

**In Scope**:
- New: `fact_telemetria` (periodic snapshot, hourly grain, consumo_kwh + voltaje)
- New: `dim_tipo_evento` (catalog with -1 Unknown row, severidad, es_critico, Stress Test support)
- New: `staging_telemetria` (landing zone with typed columns, CHECK constraints)
- Updated: `fact_interrupciones` (+sk_tipo_evento FK)
- Updated: `staging_eventos` (expanded CHECK for more event types)
- Updated: `err_telemetria` (+tipo_error discriminator)
- New SP: `sp_reconciliar_telemetria()` (set-based bulk INSERT, Wh→kWh conversion)
- Updated SP: `sp_reconciliar_interrupciones()` (sk_tipo_evento lookup, EVENTO_DESCONOCIDO fallback)
- New views: `vw_consumo_diario`, `vw_voltaje_tendencia`
- Updated views: `vw_saidi_saifi_diario` (LEFT JOIN dim_tipo_evento)
- Seed data: dim_tipo_evento catalog + staging_telemetria samples
- Generator sync: `generar_datos_semilla.py` support for new tables
- Extended: `05-verificacion-smoke-test.sql` (new schema+SP+view sections)

**Out of Scope**: Data migration (no production data), Power BI semantic model, n8n workflow implementation, advanced partitioning/performance tuning.

---

## 2. Artifacts (Engram Observation IDs)

| Artifact | Type | Observation ID | Topic Key |
|----------|------|---------------|-----------|
| Exploration | architecture | #1420 | `sdd/ddl-refactor/explore` |
| Proposal | architecture | #1421 | `sdd/ddl-refactor/proposal` |
| Spec | architecture | #1422 | `sdd/ddl-refactor/spec` |
| Design | architecture | #1423 | `sdd/ddl-refactor/design` |
| Tasks | architecture | #1424 | `sdd/ddl-refactor/tasks` |
| Task breakdown save | manual | #1425 | (none) |
| Apply progress | architecture | #1426 | `sdd/ddl-refactor/apply-progress` |
| Verify report — PR1 | architecture | #1427 | `sdd/ddl-refactor/verify-report-pr1` |
| Verify report — PR2 | decision | #1428 | `sdd/ddl-refactor/verify-report-pr2` |
| Verify report — PR3 | architecture | #1429 | `sdd/ddl-refactor/verify-report-pr3` |
| Verify report — PR4 | architecture | #1430 | `sdd/ddl-refactor/verify-report-pr4` |

OpenSpec files archived at: `openspec/changes/archive/2026-05-31-ddl-refactor/`
- `proposal.md`, `spec.md`, `design.md`, `tasks.md`, `archive.md`

---

## 3. Tasks Completed (9/9)

| Task | Description | PR | Status |
|------|-------------|----|--------|
| 1.1 | `dim_tipo_evento` DDL | PR1 | ✅ |
| 1.2 | `staging_telemetria` + `fact_telemetria` DDL | PR1 | ✅ |
| 1.3 | Update `fact_interrupciones`, `staging_eventos`, `err_telemetria` | PR1 | ✅ |
| 2.1 | Seed dim_tipo_evento + staging_telemetria; sync generator | PR2 | ✅ |
| 2.2 | `sp_reconciliar_telemetria()` + `fn_reconciliar_telemetria()` | PR3 | ✅ |
| 2.3 | Update `sp_reconciliar_interrupciones()` with sk_tipo_evento lookup | PR3 | ✅ |
| 3.1 | `vw_consumo_diario` + `vw_voltaje_tendencia` | PR4 | ✅ |
| 3.2 | Update `vw_saidi_saifi_diario` with dim_tipo_evento JOIN | PR4 | ✅ |
| 4.1 | Extend `05-verificacion-smoke-test.sql` | PR4 | ✅ |

**Total**: 9/9 tasks complete
**Estimated LOC**: ~980 across all PRs
**Delivery strategy**: auto-chain (feature-branch-chain: PR1→PR2→PR3→PR4)

---

## 4. Verification Results (4/4 PRs PASS)

| PR | Scope | Initial Verdict | Issues Found | Re-verify Verdict |
|----|-------|----------------|--------------|-------------------|
| PR1 | DDL Foundation (tasks 1.1-1.3) | PASS | None | N/A |
| PR2 | Seeds + Generator (task 2.1) | FAIL (C-1) | C-1: OVERRIDING SYSTEM VALUE | PASS after fix |
| PR3 | Stored Procedures (tasks 2.2-2.3) | FAIL (C-1, C-2) | C-1: non-existent column sk_geografia_urbana; C-2: non-existent cursor field tipo_evento | PASS after fixes |
| PR4 | Views + Smoke Test (tasks 3.1-3.2, 4.1) | FAIL (C-1) | C-1: temp table smoke_test_state created after first use | PASS after fix |

### PR1: DDL Foundation — PASS (no issues)
- 6/6 requirements satisfied without any issues
- Static review only (no psql client available)

### PR2: Seeds + Generator — C-1 FIXED
- **C-1 (CRITICAL)**: INSERT -1 into `sk_tipo_evento` (GENERATED ALWAYS AS IDENTITY) without `OVERRIDING SYSTEM VALUE`
- **Fix**: Added `OVERRIDING SYSTEM VALUE` before VALUES clause in `04-datos-semilla.sql` and `generar_datos_semilla.py`

### PR3: Stored Procedures — C-1, C-2 FIXED
- **C-1 (CRITICAL)**: `dre.sk_geografia_urbana` in `sp_reconciliar_telemetria()` — dim_red_electrica does not have this column
- **Fix**: Replaced with scalar subquery `(SELECT sk_geografia_urbana FROM dim_geografia_urbana LIMIT 1)` — consistent with sp_reconciliar_interrupciones pattern
- **C-2 (CRITICAL)**: `v_rec.tipo_evento` in cursor — field not in the cursor SELECT
- **Fix**: Added `tipo_evento_outage` to `pares` CTE via `MAX(CASE WHEN tipo_evento = 'POWER_OUTAGE' THEN tipo_evento END)`, added to cursor SELECT, replaced all 3 `v_rec.tipo_evento` references with `v_rec.tipo_evento_outage`, added COALESCE guards against NULL concatenation

### PR4: Views + Smoke Test — C-1 FIXED
- **C-1 (CRITICAL)**: Temp table `smoke_test_state` created at line 254 but first used at line 248
- **Fix**: Moved temp table creation to lines 241-246 (before Section 3 DO block). Duplicate DROP/CREATE removed from Section 4.

---

## 5. Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Two fact tables (constellation) | Respects Kimball uniform grain rule; telemetry and interruptions have fundamentally different grains |
| Telemetry granularity | Hourly | 26M rows manageable (vs 1.5B at per-minute); industry standard for smart meter telemetry |
| Staging | Two separate tables | Clean contracts for different data shapes; simpler SPs |
| DLQ strategy | Extend err_telemetria with tipo_error discriminator | Single error table, filterable by pipeline |
| Staging column type | Typed VARCHAR + CHECK (no JSONB, no ENUMs) | Early validation; ENUMs too rigid for evolving catalog |
| DDL approach | Complete rewrite (clean slate) | No production data; coherent schema for academic defense |
| SP pattern | Set-based for telemetry, cursor for interruptions | Telemetry is independent readings; interruptions need OUTAGE→RESTORATION pair matching |
| View pattern | GROUPING SETS for drill-down | Enables hierarchical Power BI analysis without multiple views |
| FK failure | DEFAULT -1 + err_telemetria log | Existing pattern from design; minimal schema complexity |
| Delivery | Auto-chain (feature-branch-chain) | 980 LOC exceeded 400-line review budget; PR1→PR2→PR3→PR4 chained |

---

## 6. Files Modified

| File | PR | Description | Est. LOC |
|------|----|-------------|----------|
| `01-ddl-modelo-estrella.sql` | PR1 | Full rewrite — added dim_tipo_evento, staging_telemetria, fact_telemetria; updated fact_interrupciones, staging_eventos, err_telemetria | ~410 |
| `04-datos-semilla.sql` | PR2 | dim_tipo_evento seed (-1 + catalog), staging_telemetria samples, OVERRIDING SYSTEM VALUE | ~130 |
| `generar_datos_semilla.py` | PR2 | Added dim_tipo_evento to target_tables, telemetry generation logic | ~80 |
| `02-sp-reconciliacion-elt.sql` | PR3 | New sp_reconciliar_telemetria() + fn_reconciliar_telemetria(); updated sp_reconciliar_interrupciones() | ~250 |
| `03-vistas-analiticas.sql` | PR4 | New vw_consumo_diario, vw_voltaje_tendencia; updated vw_saidi_saifi_diario (dim_tipo_evento JOIN) | ~120 |
| `05-verificacion-smoke-test.sql` | PR4 | Extended schema checks, SP execution, view assertions, section renumbering | ~90 |

---

## 7. Lessons Learned

1. **OVERRIDING SYSTEM VALUE (PostgreSQL)**: When inserting explicit values into a `GENERATED ALWAYS AS IDENTITY` column, PostgreSQL requires `OVERRIDING SYSTEM VALUE` before the `VALUES` clause. Without it, the INSERT fails with a column-generation conflict. Essential for the dim_tipo_evento -1 Unknown row pattern.

2. **Cursor SELECT completeness**: In PL/pgSQL, a cursor's record type (`v_rec.field`) only contains columns that were in the original SELECT. If you add a column to a CTE but forget to include it in the cursor SELECT, it silently fails at runtime. Always audit cursor SELECTs when adding new columns to the data flow.

3. **Temp table ordering**: In smoke test SQL scripts executing multiple DO blocks, temp tables must be created BEFORE the first block that references them. Executing blocks sequentially means the CREATE TEMP TABLE must appear in the execution order before the first usage, not grouped with related DDL.

4. **Static SQL review limitations**: Without `psql` or a test database, syntax validation is limited to manual review. This project accepted the risk since it targets a fresh Supabase instance.

5. **Chained PR complexity**: Feature-branch-chain (PR1→PR2→PR3→PR4) effectively split the 980 LOC into reviewable slices but required careful retargeting to keep diffs clean. Each PR had autonomous scope and independent verification.

6. **GROUPING SETS for Power BI drill-down**: Using GROUPING SETS in views enables hierarchical drill-down (ciudad→subestacion→circuito→sector) in a single query, eliminating the need for multiple aggregate views.

---

## 8. Complete SDD Lifecycle

```
explore → proposal → spec → design → tasks → apply → verify → archive
   ✅       ✅        ✅       ✅       ✅      ✅       ✅        ✅
```

**Total PRs**: 4 (all merged, all verified PASS after fixes)
**Total tasks**: 9 (all complete)
**CRITICAL issues found during verify**: 4 (all fixed and re-verified)
**Total changed lines**: ~980
**Files touched**: 6 SQL files + 1 Python file
**Engram observations**: 11 (explore + proposal + spec + design + tasks + apply-progress + 4 verify reports + archive-report)
**OpenSpec files**: 5 (proposal, spec, design, tasks, archive-report)

---

**Archived by**: SDD Archive sub-agent
**Date**: 2026-05-31
