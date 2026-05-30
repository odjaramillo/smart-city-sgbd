# Analytical Views Specification

## Purpose
Define the requirements and scenarios for the database analytical views that expose SAIDI/SAIFI KPIs, ensuring resilience to time-drift and correct temporal logic under the Kimball star schema.

## Requirements

### Requirement: Dynamic Relative Time Anchor
The analytical views MUST resolve the current analysis time anchor dynamically based on the maximum date present in `fact_interrupciones` instead of hardcoding `NOW()`.

#### Scenario: Substation ranking filters by maximum data year
- GIVEN the table `fact_interrupciones` contains records where `timestamp_inicio` spans from 2025-01-01 to 2025-03-31
- WHEN the view `vw_ranking_subestaciones` is queried in the year 2026
- THEN the query MUST anchor its year filter dynamically to the year 2025 (the maximum year of the facts)
- AND it MUST NOT return 0 rows.

### Requirement: Robust Rolling Month Window
The trend view `vw_tendencia_12_meses` MUST calculate its rolling monthly window using PostgreSQL native date intervals instead of integer math on YYYYMM format.

#### Scenario: 24-Month Trend resolves window correctly without month math bugs
- GIVEN the maximum date of events in `fact_interrupciones` is 2025-02-15
- WHEN the view `vw_tendencia_12_meses` is queried
- THEN it MUST include events between 2023-02-15 and 2025-02-15 using `INTERVAL '24 months'` subtraction
- AND it MUST NOT exclude the year 2025 due to YYYYMM integer division/subtraction errors.
