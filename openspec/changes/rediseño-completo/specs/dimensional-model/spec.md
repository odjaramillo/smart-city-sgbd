# Dimensional Model Specification

## Purpose

Define a robust Kimball star schema ensuring data integrity, correct granularity, and historical tracking for the Smart City SGBD project.

## Requirements

### Requirement: Medidor to Geografia Relationship

The system MUST guarantee a precise 1-to-n relationship mapping from geography to meter without using arbitrary limits.

#### Scenario: Insert medidor mapping
- GIVEN a new meter event mapping to a valid urban sector
- WHEN the dimensional mapping is inserted
- THEN the insert succeeds associating the precise sector ID
- AND no `LIMIT 1` or non-deterministic mapping fallback is used

### Requirement: Time Dimension Hierarchy

The system MUST provide a `dim_tiempo` with atomic granularity down to the day level and accurate hierarchical rollups.

#### Scenario: Date retrieval by hierarchy
- GIVEN a valid timestamp of an event
- WHEN the time dimension is joined
- THEN the system provides Year, Quarter, Month, and Day correctly extracted

### Requirement: Asset Health Tracking (SCD Type 2)

The system MUST track the historical status of assets using Slowly Changing Dimensions Type 2.

#### Scenario: Asset status update
- GIVEN an existing asset with an active status
- WHEN a new status change event arrives
- THEN the existing record's `valid_to` date is closed
- AND a new record is inserted with the new status and `valid_to` as NULL or infinity

### Requirement: Data Integrity Constraints

The dimensional model MUST enforce data integrity via strict relational constraints.

#### Scenario: Foreign key violation prevention
- GIVEN a fact record pointing to a non-existent dimension key
- WHEN the fact is inserted
- THEN the database REJECTS the insert due to a Foreign Key constraint

#### Scenario: Uniqueness enforcement
- GIVEN an attempt to insert a duplicate business key in a dimension
- WHEN the insert occurs
- THEN the database REJECTS the insert due to a UNIQUE constraint
