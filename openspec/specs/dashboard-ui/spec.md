# Dashboard UI Specification

## Purpose
Define the requirements and scenarios for the dashboard user interface, ensuring premium design quality, consistent rendering of Plotly charts, and responsiveness.

## Requirements

### Requirement: Premium Aesthetics and Theming
The dashboard UI MUST use a custom dark style with an HSL-tailored palette (replacing standard Bootstrap themes), smooth gradients, and rounded borders.

#### Scenario: Rendering dashboard panels with custom dark styles
- GIVEN the dashboard stylesheet is loaded
- WHEN a user opens the page in a browser
- THEN the background color MUST be a tailored charcoal/dark grey (`#121212` or equivalent HSL)
- AND cards MUST exhibit subtle hover effects (e.g. lift transitions and glow).

### Requirement: Chart Layout and Contrast
The Plotly figures MUST render with transparent backgrounds and high contrast colors to match the dashboard theme.

#### Scenario: Visual charts render with dark-mode compatibility
- GIVEN a chart is rendered inside a card component
- WHEN the page loads
- THEN the Plotly figure paper and plotting backgrounds MUST be transparent (`rgba(0,0,0,0)`)
- AND grid lines and label texts MUST be clearly visible.

### Requirement: Data Rendering Safety
All dashboard panels MUST display active visualizations and metrics instead of empty states when facts exist.

#### Scenario: Charts render valid data points
- GIVEN the database views are successfully corrected and populated
- WHEN the dashboard page is requested
- THEN the trend, ranking, and heatmap components MUST render Plotly graph elements containing data points
- AND no charts should fall back to "(sin datos)" states.
