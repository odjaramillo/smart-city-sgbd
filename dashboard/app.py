"""
Docker Dashboard — main Dash application entry point.
Uses Dash Bootstrap Components with DARKLY theme for a professional dark UI.
"""

import dash
from dash import html, dcc
import dash_bootstrap_components as dbc

from dashboard.data import queries
from dashboard.layouts import overview, drilldown, heatmap, ops
from dashboard.components import filters

app = dash.Dash(
    __name__,
    external_stylesheets=[dbc.themes.DARKLY],
    suppress_callback_exceptions=True,
)
server = app.server  # expose server for gunicorn deployment

# Header
header = dbc.Navbar(
    dbc.Container(
        [
            html.A(
                dbc.Row(
                    [
                        dbc.Col(
                            html.I(className="bi bi-lightning-charge-fill me-2", style={"font-size": "1.5rem"}),
                            width="auto",
                        ),
                        dbc.Col(dbc.NavbarBrand("Smart City — Dashboard ELÉCTRICO", className="ms-2")),
                    ],
                    align="center",
                    className="g-0",
                ),
                href="#",
                style={"textDecoration": "none", "color": "inherit"},
            ),
        ],
        fluid=True,
    ),
    color="dark",
    dark=True,
    className="dashboard-header",
)

# Main layout
app.layout = dbc.Container(
    [
        header,
        # Filters bar
        dbc.Row(
            dbc.Col(
                filters.filters_bar(),
                width=12,
            ),
            className="filters-row",
        ),
        # dcc.Store for shared state (drill-down path, cross-filter values)
        dcc.Store(id="drilldown-state", data={"level": "ciudad", "breadcrumb": ["Ciudad"]}),
        dcc.Store(id="filter-state", data={}),
        # Main content area
        dbc.Row(
            dbc.Col(
                html.Div(
                    [
                        # Row 1: KPI cards
                        overview.kpi_row(),
                        # Row 2: Trend chart (left) + Ranking bar (right)
                        dbc.Row(
                            [
                                dbc.Col(
                                    overview.trend_line_chart(None),
                                    width=8,
                                    className="chart-col",
                                ),
                                dbc.Col(
                                    overview.ranking_bar_chart(None),
                                    width=4,
                                    className="chart-col",
                                ),
                            ],
                            className="section-row",
                        ),
                        # Row 3: Drill-down table (left) + Heatmap (right)
                        dbc.Row(
                            [
                                dbc.Col(
                                    drilldown.drilldown_table(None),
                                    width=6,
                                    className="table-col",
                                ),
                                dbc.Col(
                                    heatmap.heatmap_chart(None),
                                    width=6,
                                    className="chart-col",
                                ),
                            ],
                            className="section-row",
                        ),
                        # Row 4: Ops panel (ELT monitoring + error audit)
                        dbc.Row(
                            dbc.Col(
                                ops.elt_status_table(None),
                                width=12,
                                className="table-col",
                            ),
                            className="section-row",
                        ),
                        dbc.Row(
                            dbc.Col(
                                ops.error_audit_chart(None),
                                width=12,
                                className="chart-col",
                            ),
                            className="section-row",
                        ),
                    ],
                    id="main-content",
                    className="main-content",
                ),
                width=12,
            ),
        ),
    ],
    fluid=True,
    className="dashboard-container",
)


if __name__ == "__main__":
    app.run_server(host="0.0.0.0", port=8050, debug=False)