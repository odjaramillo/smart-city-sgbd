"""
Reusable Plotly chart builders for the dashboard.
Provides trend line, ranking bar, heatmap, and error trend charts.
"""

from dash import dcc
import plotly.express as px
import plotly.graph_objects as go


def trend_line_chart(df):
    """
    Plotly line chart for vw_tendencia_12_meses.
    Shows SAIDI and SAIFI city-level trends over time.

    Args:
        df: DataFrame with columns anio, mes, nombre_mes, periodo_orden,
            saidi_ciudad, saifi_ciudad, total_interrupciones

    Returns:
        dcc.Graph with the line chart figure
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Tendencia SAIDI/SAIFI (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
        )
    else:
        fig = go.Figure()
        fig.add_trace(
            go.Scatter(
                x=df["periodo_orden"],
                y=df["saidi_ciudad"],
                name="SAIDI",
                mode="lines+markers",
                line=dict(color="#00b4d8", width=2),
                marker=dict(size=6),
            )
        )
        fig.add_trace(
            go.Scatter(
                x=df["periodo_orden"],
                y=df["saifi_ciudad"],
                name="SAIFI",
                mode="lines+markers",
                line=dict(color="#ff6b6b", width=2),
                marker=dict(size=6),
            )
        )
        fig.update_layout(
            title="Tendencia SAIDI / SAIFI por Mes",
            xaxis_title="Periodo",
            yaxis_title="Índice",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
            margin=dict(l=40, r=20, t=50, b=40),
        )
        fig.update_xaxes(
            tickangle=-45,
            tickmode="array",
            tickvals=df["periodo_orden"],
            ticktext=df["periodo"] if "periodo" in df.columns else df["periodo_orden"],
        )

    return dcc.Graph(
        id="trend-chart",
        figure=fig,
        config={"displayModeBar": False},
        className="chart-panel",
    )


def ranking_bar_chart(df):
    """
    Plotly horizontal bar chart with traffic-light colors.
    Shows substation ranking by SAIDI average.

    Args:
        df: DataFrame with columns ranking, subestacion, saidi_promedio, nivel_desempeno

    Returns:
        dcc.Graph with the bar chart figure
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Ranking Subestaciones (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
        )
    else:
        color_map = {
            "Óptimo": "#2ecc71",
            "Bueno": "#27ae60",
            "Regular": "#f39c12",
            "Deficiente": "#e74c3c",
            "Crítico": "#c0392b",
        }
        df = df.copy()
        df["color"] = df["nivel_desempeno"].map(color_map).fill("#95a5a6")

        fig = go.Figure()
        fig.add_trace(
            go.Bar(
                y=df["subestacion"],
                x=df["saidi_promedio"],
                orientation="h",
                marker_color=df["color"],
                text=df["saidi_promedio"].apply(lambda v: f"{v:.1f}"),
                textposition="outside",
                insidetextanchor="start",
            )
        )
        fig.update_layout(
            title="Ranking SAIDI por Subestación",
            xaxis_title="SAIDI Promedio (min)",
            yaxis_title="",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            showlegend=False,
            margin=dict(l=120, r=20, t=50, b=40),
            yaxis=dict(autorange="reversed"),
        )

    return dcc.Graph(
        id="ranking-chart",
        figure=fig,
        config={"displayModeBar": False},
        className="chart-panel",
    )


def heatmap_chart(df):
    """
    Plotly heatmap for vw_heatmap_interrupciones.
    Shows interruptions by hour x day-of-week.

    Args:
        df: DataFrame with columns hora, dia_semana, dia_semana_num, total_interrupciones

    Returns:
        dcc.Graph with the heatmap figure
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Mapa de Calor (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
        )
    else:
        pivot = df.pivot_table(
            index="dia_semana",
            columns="hora",
            values="total_interrupciones",
            aggfunc="sum",
            fill_value=0,
        )
        fig = go.Figure(
            data=go.Heatmap(
                z=pivot.values,
                x=pivot.columns,
                y=pivot.index,
                colorscale="YlOrRd",
                colorbar=dict(title="Interruptions"),
                hovertemplate="Día: %{y}<br>Hora: %{x}:00<br>Interrupciones: %{z}<extra></extra>",
            )
        )
        fig.update_layout(
            title="Interruptiones por Hora y Día de la Semana",
            xaxis_title="Hora del día",
            yaxis_title="Día de la semana",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            margin=dict(l=60, r=20, t=50, b=50),
            xaxis=dict(dtick=2),
        )

    return dcc.Graph(
        id="heatmap-chart",
        figure=fig,
        config={"displayModeBar": False},
        className="chart-panel",
    )


def error_trend_chart(df):
    """
    Plotly area chart for vw_auditoria_errores.
    Shows error volume trend over time.

    Args:
        df: DataFrame with columns fecha, total_errores, medidores_afectados

    Returns:
        dcc.Graph with the area chart figure
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Auditoría de Errores (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
        )
    else:
        df = df.sort_values("fecha")
        fig = go.Figure()
        fig.add_trace(
            go.Scatter(
                x=df["fecha"],
                y=df["total_errores"],
                name="Total Errores",
                mode="lines",
                fill="tozeroy",
                line=dict(color="#e74c3c"),
                fillcolor="rgba(231,76,60,0.3)",
            )
        )
        fig.update_layout(
            title="Auditoría de Errores",
            xaxis_title="Fecha",
            yaxis_title="Total Errores",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
            margin=dict(l=40, r=20, t=50, b=40),
        )

    return dcc.Graph(
        id="error-trend-chart",
        figure=fig,
        config={"displayModeBar": False},
        className="chart-panel",
    )