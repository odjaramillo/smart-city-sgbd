"""
Dashboard filter components.
Provides date range, sector, criticality, and MED exclusion filters.
"""

from dash import dcc, html
import dash_bootstrap_components as dbc


def date_range_picker():
    """Date range picker using dcc.DatePickerRange."""
    return dcc.DatePickerRange(
        id="date-range",
        start_date="2024-01-01",
        end_date="2024-12-31",
        display_format="YYYY-MM-DD",
        style={"width": "100%"},
    )


def sector_dropdown(sectors=None):
    """
    Sector dropdown populated from dim_geografia_urbana.
    If sectors list not provided, uses a placeholder.
    """
    options = []
    if sectors is not None:
        options = [{"label": s, "value": s} for s in sectors]
    else:
        options = [{"label": "Todos los sectores", "value": "ALL"}]

    return dcc.Dropdown(
        id="sector-filter",
        options=options,
        value="ALL",
        clearable=True,
        placeholder="Seleccionar sector...",
        style={"min-width": "180px"},
    )


def criticality_dropdown():
    """
    Criticality dropdown with standard levels.
    """
    options = [
        {"label": "Todos los niveles", "value": "ALL"},
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
    """
    Checklist to exclude Major Event Days from metrics.
    """
    return dcc.Checklist(
        id="med-toggle",
        options=[{"label": "Excluir MED", "value": "excluir_med"}],
        value=[],
        style={"margin-bottom": "0"},
    )


def filters_bar(sectors=None):
    """
    Combines all filters in a horizontal bar.
    Returns a dbc.Row with filter components.
    """
    return dbc.Row(
        [
            dbc.Col(
                html.Div(
                    [
                        dbc.Label("Rango de Fechas", html_for="date-range", className="filter-label"),
                        date_range_picker(),
                    ]
                ),
                width="auto",
                className="filter-col",
            ),
            dbc.Col(
                html.Div(
                    [
                        dbc.Label("Sector", html_for="sector-filter", className="filter-label"),
                        sector_dropdown(sectors),
                    ]
                ),
                width="auto",
                className="filter-col",
            ),
            dbc.Col(
                html.Div(
                    [
                        dbc.Label("Criticidad", html_for="criticality-filter", className="filter-label"),
                        criticality_dropdown(),
                    ]
                ),
                width="auto",
                className="filter-col",
            ),
            dbc.Col(
                html.Div(
                    [
                        dbc.Label("", html_for="med-toggle"),
                        med_toggle(),
                    ]
                ),
                width="auto",
                className="filter-col med-toggle-col",
            ),
        ],
        className="filters-bar g-3 align-items-center",
    )