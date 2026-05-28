# Dashboard UI Specification

## Purpose

Define the user interface requirements and backend integration for the Dash application visualizing reliability indices.

## Requirements

### Requirement: Modern Dash Bootstrap Components

The UI MUST use `dash-bootstrap-components` >= 1.5.0 and avoid deprecated elements.

#### Scenario: Form rendering
- GIVEN the application UI is loaded
- WHEN form inputs are rendered
- THEN standard layout structures are used
- AND NO deprecated `dbc.FormGroup` components are present

### Requirement: Global Connection Pooling

The backend integration MUST maintain an application-level SQLAlchemy connection pool.

#### Scenario: Multiple concurrent dashboard requests
- GIVEN high traffic to the dashboard
- WHEN data is queried in callbacks
- THEN the dashboard reuses a module-level engine
- AND does not invoke `create_engine()` inside every callback execution

### Requirement: Safe DataFrame Error Handling

The application MUST explicitly handle empty states and NaN values correctly.

#### Scenario: Missing data formatting
- GIVEN a Pandas DataFrame containing NaN values returned from the database
- WHEN the data is prepared for the UI
- THEN `.fillna()` is used to resolve missing values
- AND NOT the invalid `.fill()` method

### Requirement: Strict Error Logging in Callbacks

The application MUST log all exceptions in Dash callbacks without silent swallowing.

#### Scenario: Callback execution failure
- GIVEN a callback that encounters an unexpected ValueError
- WHEN the callback fails
- THEN the error and stack trace are written to the application log
- AND an error state is correctly propagated to the user interface

### Requirement: Dynamic UI Filters

The application MUST populate dropdown filters dynamically from the database.

#### Scenario: Filter initialization
- GIVEN the dashboard loads
- WHEN the filters for Sector, Fecha, and Criticidad are displayed
- THEN their options are fetched directly from dimension tables in the database

### Requirement: Hierarchical Drill-down

The dashboard MUST support drill-down navigation through the asset hierarchy.

#### Scenario: Granularity drill-down navigation
- GIVEN the user views City-level metrics
- WHEN the user selects a specific City
- THEN the view updates to show Substation-level metrics
- AND allows further drill-down to Circuit and Transformer levels

### Requirement: Docker Deployment Isolation

The Docker configuration MUST NOT overwrite application code at runtime improperly.

#### Scenario: Container execution
- GIVEN the dashboard container is spun up via `docker-compose`
- WHEN the container mounts volumes
- THEN the `/app` directory is mounted safely without masking generated assets or permissions
