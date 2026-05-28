# Analytical Views Specification

## Purpose

Define the required logic for materialized and logical views that calculate IEEE 1366 reliability indices.

## Requirements

### Requirement: IEEE 1366 Compliance (SAIDI/SAIFI)

The views MUST calculate SAIDI and SAIFI precisely according to the IEEE 1366 standard.

#### Scenario: SAIDI Calculation
- GIVEN a set of outage events
- WHEN SAIDI is calculated
- THEN the total duration of interruptions is divided by `total_clientes_servidos`
- AND NOT divided by `total_clientes_afectados`

#### Scenario: SAIFI Calculation
- GIVEN a set of outage events
- WHEN SAIFI is calculated
- THEN the total number of customer interruptions is divided by `total_clientes_servidos`

### Requirement: Safe Granularity Segregation

The views MUST NOT aggregate mismatched granularities that cause Cartesian products or duplicate counts.

#### Scenario: Substation level aggregation
- GIVEN a hierarchical schema (City -> Substation -> Circuit -> Transformer)
- WHEN querying metrics per Substation
- THEN the view explicitly filters or groups at the Substation level without rolling up unintended Cartesian duplicates from Transformers

### Requirement: Native Date Math

The analytical views MUST compute duration and time differences using native PostgreSQL `INTERVAL` types.

#### Scenario: Outage duration calculation
- GIVEN an outage with a start timestamp and an end timestamp
- WHEN the duration is computed
- THEN the result is generated via `end_time - start_time` yielding an `INTERVAL`
- AND NOT through integer arithmetic that assumes fixed second counts per day

### Requirement: Major Event Day (MED) Classification

The views MUST establish MED thresholds based on historical baselines.

#### Scenario: MED threshold application
- GIVEN a calculated baseline for system reliability
- WHEN identifying major event days
- THEN days exceeding the MED threshold are flagged
- AND the threshold is calculated without mutually excluding the baseline data itself erroneously
