"""
Dashboard filter components.
Provides date range, sector, criticality, and MED exclusion filters.
"""

from dash import dcc, html
import dash_bootstrap_components as dbc


def date_range_picker():
    return dcc.DatePickerRange(
        id="date-range",
        start_date="2024-01-01",
        end_date="2024-12-31",
        display_format="YYYY-MM-DD",
        style={"width": "100%"},
    )


def sector_dropdown(sectors=None):
    options = [{"label": "Todos los sectores", "value": "ALL"}]
    if sectors:
        options = [{"label": "Todos los sectores", "value": "ALL"}] + [
            {"label": s, "value": s} for s in sectors
        ]

    return dcc.Dropdown(
        id="sector-filter",
        options=options,
        value="ALL",
        clearable=True,
        placeholder="Seleccionar sector...",
        style={"min-width": "180px"},
    )


def criticality_dropdown(levels=None):
    options = [{"label": "Todos los niveles", "value": "ALL"}]
    if levels:
        options += [{"label": lvl, "value": lvl} for lvl in levels]
    else:
        options += [
            {"label": "Crítico", "value": "CRITICO"},
            {"label": "Alto", "value": "ALTO"},
            {"label": "Medio", "value": "MEDIO"},
            {"label": "Normal", "value": "NORMAL"},
            {"label": "Bajo", "value": "BAJO"},
        ]

    return dcc.Dropdown(
        id="criticality-filter",
        options=options,
        value="ALL",
        clearable=False,
        style={"min-width": "150px"},
    )


def med_toggle():
    return dcc.Checklist(
        id="med-toggle",
        options=[{"label": "Excluir MED", "value": "excluir_med"}],
        value=[],
        style={"margin-bottom": "0"},
    )


def filters_bar(sectors=None, criticality_levels=None):
    return dbc.Row(
        [
            dbc.Col(
                [
                    dbc.Label("Rango de Fechas", html_for="date-range", className="filter-label"),
                    date_range_picker(),
                ],
                width="auto",
                className="filter-col",
            ),
            dbc.Col(
                [
                    dbc.Label("Sector", html_for="sector-filter", className="filter-label"),
                    sector_dropdown(sectors),
                ],
                width="auto",
                className="filter-col",
            ),
            dbc.Col(
                [
                    dbc.Label("Criticidad", html_for="criticality-filter", className="filter-label"),
                    criticality_dropdown(criticality_levels),
                ],
                width="auto",
                className="filter-col",
            ),
            dbc.Col(
                [
                    dbc.Label("", html_for="med-toggle"),
                    med_toggle(),
                ],
                width="auto",
                className="filter-col med-toggle-col",
            ),
        ],
        className="filters-bar g-3 align-items-center",
    )
