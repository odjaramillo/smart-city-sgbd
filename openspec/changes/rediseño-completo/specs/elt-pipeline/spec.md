# ELT Pipeline Specification

## Purpose

Define the transactional, fail-fast Extract, Load, and Transform (ELT) processes for loading raw events into the dimensional model.

## Requirements

### Requirement: Transactional Sequence Handling

The system MUST fetch and manage database sequences safely without relying on session state assumptions (e.g., `currval` without prior `nextval`).

#### Scenario: Sequence retrieval in batch
- GIVEN a new batch load procedure
- WHEN new dimensional records are generated
- THEN keys are retrieved using `RETURNING` clauses or explicit `OUT` parameters per row

### Requirement: Cross-Batch Event Pairing

The pipeline MUST pair events that span multiple batches without losing connections due to time-based boundaries.

#### Scenario: Multi-batch event resolution
- GIVEN an outage event started in batch A and restored in batch B
- WHEN batch B is processed
- THEN the ELT process pairs the restoration event with the open outage from batch A without artificially filtering staging data by the current batch date

### Requirement: Safe Concurrency Controls

The pipeline MUST handle parallel ELT runs safely without deadlocks or duplicated processing.

#### Scenario: Concurrent batch runs
- GIVEN two concurrent executions of the ELT procedure trying to process the same events
- WHEN fetching staging rows
- THEN the system uses `FOR UPDATE SKIP LOCKED`
- AND only one execution processes a given row

### Requirement: Fail-Fast Mechanism

The system MUST fail fast upon encountering anomalous conditions instead of applying silent fallbacks that corrupt data.

#### Scenario: Invalid event state transition
- GIVEN an event that transitions to an impossible status
- WHEN the ELT process validates the event
- THEN the process aborts with an explicit error
- AND the transaction is rolled back

### Requirement: Optimal Table Scans

The pipeline MUST avoid full table scans for incremental loads.

#### Scenario: Incremental update
- GIVEN a staging table with millions of rows
- WHEN the ELT updates recent events
- THEN the process uses indexed lookups on active records only
