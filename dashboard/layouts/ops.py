"""
Operations monitoring layout.
ELT batch status table + error audit chart.
"""

from dash import html, dash_table
import dash_bootstrap_components as dbc

from dashboard.components.charts import error_trend_chart


def elt_status_table(elt_df=None):
    """
    Table showing recent ELT batch processing status.
    Columns: id_lote, fecha_ejecucion, estado, total_eventos, tasa_error_pct, duracion_segundos

    Args:
        elt_df: DataFrame with ELT monitoring data
    """
    columns = [
        {"name": "Lote", "id": "id_lote", "type": "numeric"},
        {"name": "Fecha Ejecución", "id": "fecha_ejecucion", "type": "datetime"},
        {"name": "Estado", "id": "estado", "type": "text"},
        {"name": "Eventos", "id": "total_eventos", "type": "numeric"},
        {"name": "Tasa Error %", "id": "tasa_error_pct", "type": "numeric", "format": {"specifier": ".2f"}},
        {"name": "Duración (s)", "id": "duracion_segundos", "type": "numeric"},
    ]

    data = elt_df.to_dict("records") if elt_df is not None and not elt_df.empty else []

    return dash_table.DataTable(
        id="elt-status-table",
        data=data,
        columns=columns,
        page_size=10,
        sort_action="native",
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
                "if": {"filter_query": "{estado} = 'Fallido'"},
                "backgroundColor": "rgba(231,76,60,0.15)",
                "color": "#e74c3c",
            },
            {
                "if": {"filter_query": "{estado} = 'Completado'"},
                "backgroundColor": "rgba(46,204,113,0.1)",
                "color": "#2ecc71",
            },
            {
                "if": {"row_index": "odd"},
                "backgroundColor": "#262626",
            },
        ],
        style_cell={"textAlign": "left", "padding": "8px"},
    )


def error_audit_chart(error_df=None):
    """
    Error audit chart for data quality monitoring.
    Wrapper around error_trend_chart.
    """
    return error_trend_chart(error_df)


def ops_section(elt_df=None, error_df=None):
    """
    Full operations monitoring section.

    Args:
        elt_df: DataFrame for ELT status table
        error_df: DataFrame for error audit chart
    """
    return html.Div(
        [
            dbc.Row(
                dbc.Col(
                    [
                        html.H5("Monitoreo ELT", className="section-title"),
                        elt_status_table(elt_df),
                    ],
                    width=12,
                ),
                className="section-row",
            ),
            dbc.Row(
                dbc.Col(
                    [
                        html.H5("Auditoría de Errores", className="section-title"),
                        error_audit_chart(error_df),
                    ],
                    width=12,
                ),
                className="section-row",
            ),
        ],
        id="ops-section",
        className="ops-layout",
    )