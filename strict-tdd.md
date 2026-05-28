# Strict TDD Mode — smart-city-sgbd

## Test Runner

- **Framework**: pytest
- **Command**: `pytest`
- **Coverage**: `pytest --cov=dashboard --cov-report=term-missing`
- **Minimum coverage**: 80%

## Red-Green-Refactor Cycle (MANDATORY)

For every task that modifies Python code:

1. **RED**: Write a failing test that describes the desired behavior
   - Test must fail for the RIGHT reason (assertion error, not import error)
   - Run `pytest` to confirm failure
   - Do NOT proceed until test fails

2. **GREEN**: Write the minimum code to make the test pass
   - No more, no less
   - Run `pytest` to confirm success
   - Do NOT refactor yet

3. **REFACTOR**: Improve code while keeping tests green
   - Remove duplication, improve names, extract helpers
   - Run `pytest` after each refactor step
   - Do NOT add new behavior

## Test Structure

```
tests/
├── unit/           # Pure functions, no DB, no Dash app
├── integration/    # DB queries, ELT logic, cross-module
└── conftest.py     # Shared fixtures (DB engine, test data)
```

## Test Naming

- Files: `test_<module>.py`
- Functions: `test_<behavior>` (e.g., `test_saidi_calculation_with_zero_outages`)
- Classes: `Test<Feature>` (e.g., `TestSAIDICalculation`)

## Fixtures

Use pytest fixtures for:
- Database connections (scoped to session)
- Test data setup/teardown
- Dash app test client

## What to Test

### Python Dashboard
- KPI calculations (SAIDI, SAIFI) with known inputs/outputs
- Data transformation functions
- Filter logic (date ranges, sectors, criticidad)
- Callback edge cases (empty data, null values)

### SQL (via pytest + psycopg2)
- Stored procedure idempotency
- Dimension population counts
- Fact table constraints (FK, CHECK, UNIQUE)
- Analytical view correctness

## What NOT to Test

- Third-party library internals (Dash, Plotly, SQLAlchemy)
- Docker Compose orchestration (test locally, not in CI)
- Visual appearance of dashboard (manual QA, not automated)

## Coverage Threshold

- **Minimum**: 80% for `dashboard/` modules
- **Target**: 90% for KPI calculation logic
- **Exclusions**: `__init__.py`, `app.py` (entry point), `config.py` (constants)

## Continuous Verification

After every `sdd-apply` task:
1. Run `pytest` to verify all tests pass
2. Run `pytest --cov=dashboard` to check coverage
3. If coverage < 80%, add tests before marking task complete

## Failure Protocol

If a test fails during `sdd-apply`:
1. **STOP** — do not continue with the task
2. Diagnose why the test failed
3. Fix the code (not the test) unless the test was wrong
4. Re-run `pytest` to confirm green
5. Only then continue with the task

## Notes

- Manual SQL smoke test (`05-verificacion-smoke-test.sql`) remains for ELT pipeline validation
- pytest complements (does not replace) the manual smoke test
- Use `pytest -v` for verbose output during development
- Use `pytest -x` to stop on first failure
