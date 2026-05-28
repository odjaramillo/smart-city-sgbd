"""
Heatmap layout for hour x day-of-week interruption analysis.
Franja horaria breakdown panel.
"""

from dash import html, dcc
import dash_bootstrap_components as dbc

from dashboard.components.charts import heatmap_chart


def heatmap_section(heatmap_df=None, franja_df=None):
    """
    Heatmap section with hour x day-of-week matrix.

    Args:
        heatmap_df: DataFrame for heatmap_chart (hora, dia_semana, total_interrupciones)
        franja_df: DataFrame for franja horaria breakdown (franja_horaria, total_interrupciones)
    """
    return html.Div(
        [
            dbc.Row(
                dbc.Col(
                    [
                        html.H5("Mapa de Calor: Interrupciones por Hora y Día", className="section-title"),
                        heatmap_chart(heatmap_df),
                    ],
                    width=8,
                ),
                className="section-row align-items-start",
            ),
            dbc.Row(
                dbc.Col(
                    [
                        html.H5("Desglose por Franja Horaria", className="section-title"),
                        html.Div(
                            id="franja-breakdown",
                            children=build_franja_list(franja_df),
                            className="franja-list",
                        ),
                    ],
                    width=4,
                ),
                className="section-row",
            ),
        ],
        id="heatmap-section",
        className="heatmap-layout",
    )


def build_franja_list(franja_df):
    """
    Build a simple list of franja horaria summaries from a DataFrame.

    Args:
        franja_df: DataFrame with franja_horaria, total_interrupciones columns
    """
    from dash import html

    if franja_df is None or franja_df.empty:
        return html.Div("Sin datos disponibles", className="text-muted")

    rows = []
    for _, row in franja_df.iterrows():
        rows.append(
            dbc.Row(
                [
                    dbc.Col(html.Span(row.get("franja_horaria", ""), className="franja-label"), width=6),
                    dbc.Col(
                        html.Span(
                            f"{row.get('total_interrupciones', 0)}",
                            className="franja-value",
                        ),
                        width=3,
                    ),
                    dbc.Col(
                        dbc.Progress(
                            value=float(row.get("total_interrupciones", 0)) / max(franja_df["total_interrupciones"].max(), 1) * 100,
                            color="danger",
                            className="franja-progress",
                        ),
                        width=3,
                    ),
                ],
                className="franja-row",
            )
        )
    return rows