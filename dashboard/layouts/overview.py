"""
City-level overview layout.
KPI cards row + trend chart + ranking chart.
"""

from dash import html
import dash_bootstrap_components as dbc

from dashboard.components.kpi_cards import kpi_row
from dashboard.components.charts import trend_line_chart, ranking_bar_chart


def overview_section(kpi_data=None, trend_df=None, ranking_df=None):
    """
    City-level overview section with KPI cards, trend, and ranking.

    Args:
        kpi_data: dict for KPI cards (see kpi_cards.kpi_row)
        trend_df: DataFrame for trend_line_chart
        ranking_df: DataFrame for ranking_bar_chart

    Returns:
        html.Div containing the overview section
    """
    return html.Div(
        [
            # Row 1: KPI cards
            dbc.Row(
                dbc.Col(kpi_row(kpi_data), width=12),
                className="section-row",
            ),
            # Row 2: Trend + Ranking
            dbc.Row(
                [
                    dbc.Col(trend_line_chart(trend_df), width=8, className="chart-col"),
                    dbc.Col(ranking_bar_chart(ranking_df), width=4, className="chart-col"),
                ],
                className="section-row",
            ),
        ],
        id="overview-section",
        className="overview-layout",
    )