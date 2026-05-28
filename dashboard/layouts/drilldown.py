"""
Hierarchical drill-down layout.
Breadcrumb: Ciudad > Subestación > Circuito > Transformador
DataTable with drill-down columns and selector dropdowns.
"""

from dash import html, dcc
import dash_bootstrap_components as dbc
from dash import dash_table


def drilldown_breadcrumb(breadcrumb=None):
    """
    Breadcrumb navigation showing drill-down path.

    Args:
        breadcrumb: list of strings representing current path, e.g. ["Ciudad", "Subestación A"]
    """
    if breadcrumb is None:
        breadcrumb = ["Ciudad"]

    items = []
    for i, item in enumerate(breadcrumb):
        if i < len(breadcrumb) - 1:
            items.append(
                dbc.BreadcrumbItem(
                    item,
                    href="#",
                    className="breadcrumb-link",
                    id=f"breadcrumb-{i}",
                )
            )
            items.append(dbc.BreadcrumbItem("", className="separator"))
        else:
            items.append(
                dbc.BreadcrumbItem(
                    item,
                    active=True,
                    className="breadcrumb-active",
                )
            )

    return dbc.Breadcrumb(items, className="drilldown-breadcrumb", id=id)


def drilldown_selectors(subestaciones=None, circuitos=None, transformadores=None):
    """
    Dropdown selectors for drill-down navigation.

    Args:
        subestaciones: list of subestacion values
        circuitos: list of circuito values
        transformadores: list of transformador values
    """
    sub_opts = [{"label": s, "value": s} for s in (subestaciones or [])]
    circ_opts = [{"label": c, "value": c} for c in (circuitos or [])]
    trans_opts = [{"label": t, "value": t} for t in (transformadores or [])]

    return dbc.Row(
        [
            dbc.Col(
                dbc.FormGroup(
                    [
                        dbc.Label("Subestación", html_for="drilldown-subestacion", className="filter-label"),
                        dcc.Dropdown(
                            id="drilldown-subestacion",
                            options=sub_opts,
                            value=None,
                            clearable=True,
                            placeholder="Todas",
                        ),
                    ]
                ),
                width=3,
            ),
            dbc.Col(
                dbc.FormGroup(
                    [
                        dbc.Label("Circuito", html_for="drilldown-circuito", className="filter-label"),
                        dcc.Dropdown(
                            id="drilldown-circuito",
                            options=circ_opts,
                            value=None,
                            clearable=True,
                            placeholder="Todos",
                        ),
                    ]
                ),
                width=3,
            ),
            dbc.Col(
                dbc.FormGroup(
                    [
                        dbc.Label("Transformador", html_for="drilldown-transformador", className="filter-label"),
                        dcc.Dropdown(
                            id="drilldown-transformador",
                            options=trans_opts,
                            value=None,
                            clearable=True,
                            placeholder="Todos",
                        ),
                    ]
                ),
                width=3,
            ),
        ],
        className="drilldown-selectors g-3",
    )


def drilldown_table(data=None, columns=None):
    """
    DataTable with drill-down metrics.
    Shows SAIDI, SAIFI, CAIDI by hierarchy level.

    Args:
        data: list of dicts for table rows
        columns: list of column definitions for DataTable
    """
    if columns is None:
        columns = [
            {"name": "Subestación", "id": "subestacion", "type": "text"},
            {"name": "Circuito", "id": "circuito", "type": "text"},
            {"name": "Transformador", "id": "transformador", "type": "text"},
            {"name": "Interrupciones", "id": "total_interrupciones", "type": "numeric"},
            {"name": "SAIDI", "id": "saidi", "type": "numeric", "format": {"specifier": ".2f"}},
            {"name": "SAIFI", "id": "saifi", "type": "numeric", "format": {"specifier": ".2f"}},
            {"name": "CAIDI", "id": "caidi", "type": "numeric", "format": {"specifier": ".2f"}},
        ]

    if data is None:
        data = []

    return dash_table.DataTable(
        id="drilldown-table",
        data=data,
        columns=columns,
        page_size=15,
        sort_action="native",
        filter_action="native",
        style_table={"overflowX": "auto"},
        style_header={
            "backgroundColor": "#2d2d2d",
            "color": "#ffffff",
            "fontWeight": "bold",
            "borderBottom": "1px solid #444",
        },
        style_data={
            "backgroundColor": "#1e1e1e",
            "color": "#e0e0e0",
            "border": "1px solid #333",
        },
        style_data_conditional=[
            {
                "if": {"row_index": "odd"},
                "backgroundColor": "#262626",
            }
        ],
        style_cell={"textAlign": "left", "padding": "8px"},
    )


def drilldown_section(breadcrumb=None, subestaciones=None, circuitos=None, transformadores=None, table_data=None):
    """
    Full drill-down section combining breadcrumb, selectors, and table.

    Args:
        breadcrumb: list for breadcrumb navigation
        subestaciones: list of subestacion values for dropdown
        circuitos: list of circuito values for dropdown
        transformadores: list of transformador values for dropdown
        table_data: list of dicts for table rows
    """
    return html.Div(
        [
            dbc.Row(
                dbc.Col(drilldown_breadcrumb(breadcrumb), width=12),
                className="section-row",
            ),
            dbc.Row(
                dbc.Col(drilldown_selectors(subestaciones, circuitos, transformadores), width=12),
                className="section-row",
            ),
            dbc.Row(
                dbc.Col(drilldown_table(table_data), width=12),
                className="section-row",
            ),
        ],
        id="drilldown-section",
        className="drilldown-layout",
    )