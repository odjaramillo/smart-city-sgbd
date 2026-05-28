"""
KPI card components for the dashboard.
Displays SAIDI, SAIFI, CAIDI, and total interruptions metrics.
"""

from dash import html
import dash_bootstrap_components as dbc


def kpi_card(title, value, delta=None, icon="bi bi-lightning-charge-fill"):
    """
    Single KPI card with title, value, optional delta, and icon.

    Args:
        title: Display title for the metric
        value: Formatted metric value
        delta: Optional percentage change vs prior period
        icon: Bootstrap Icons class for the card icon
    """
    delta_element = ""
    if delta is not None:
        delta_color = "text-success" if delta >= 0 else "text-danger"
        delta_element = html.Div(
            f"{delta:+.1f}% vs periodo anterior",
            className=f"kpi-delta {delta_color}",
        )

    return dbc.Card(
        dbc.CardBody(
            [
                html.Div(
                    [
                        html.I(className=icon, style={"font-size": "1.5rem"}),
                    ],
                    className="kpi-icon",
                ),
                html.H5(title, className="kpi-title"),
                html.H2(value, className="kpi-value"),
                delta_element,
            ],
        ),
        className="kpi-card",
    )


def kpi_row(kpi_data=None):
    """
    Row with 4 KPI cards: SAIDI ciudad, SAIFI ciudad, CAIDI ciudad, total interrupciones.

    Args:
        kpi_data: dict with keys saidi, saifi, caidi, total_interrupciones
                  Each value is a dict with 'value', 'delta' (optional), 'icon' (optional)
    """
    if kpi_data is None:
        kpi_data = {
            "saidi": {"value": "—", "delta": None, "icon": "bi bi-clock-fill"},
            "saifi": {"value": "—", "delta": None, "icon": "bi bi-people-fill"},
            "caidi": {"value": "—", "delta": None, "icon": "bi bi-stopwatch-fill"},
            "total_interrupciones": {"value": "—", "delta": None, "icon": "bi bi-lightning-charge-fill"},
        }

    cards = [
        kpi_card(
            title="SAIDI Ciudad",
            value=kpi_data["saidi"].get("value", "—"),
            delta=kpi_data["saidi"].get("delta"),
            icon=kpi_data["saidi"].get("icon", "bi bi-clock-fill"),
        ),
        kpi_card(
            title="SAIFI Ciudad",
            value=kpi_data["saifi"].get("value", "—"),
            delta=kpi_data["saifi"].get("delta"),
            icon=kpi_data["saifi"].get("icon", "bi bi-people-fill"),
        ),
        kpi_card(
            title="CAIDI Ciudad",
            value=kpi_data["caidi"].get("value", "—"),
            delta=kpi_data["caidi"].get("delta"),
            icon=kpi_data["caidi"].get("icon", "bi bi-stopwatch-fill"),
        ),
        kpi_card(
            title="Total Interrupciones",
            value=kpi_data["total_interrupciones"].get("value", "—"),
            delta=kpi_data["total_interrupciones"].get("delta"),
            icon=kpi_data["total_interrupciones"].get("icon", "bi bi-lightning-charge-fill"),
        ),
    ]

    return dbc.Row([dbc.Col(card, width=3) for card in cards], className="kpi-row g-4")