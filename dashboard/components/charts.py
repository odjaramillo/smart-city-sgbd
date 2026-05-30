"""
Reusable Plotly chart builders for the dashboard.
Provides trend line, ranking bar, heatmap, and error trend charts with premium styles.
"""

from dash import dcc
import plotly.express as px
import plotly.graph_objects as go


def trend_line_chart(df):
    """
    Plotly line chart for vw_tendencia_12_meses.
    Shows SAIDI and SAIFI city-level trends over time.
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Tendencia SAIDI/SAIFI (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            font=dict(family="Outfit, sans-serif")
        )
    else:
        fig = go.Figure()
        fig.add_trace(
            go.Scatter(
                x=df["periodo_orden"],
                y=df["saidi_ciudad"],
                name="SAIDI (Minutos)",
                mode="lines+markers",
                line=dict(color="#00e5ff", width=3),
                marker=dict(size=8, color="#00e5ff", symbol="circle"),
                hovertemplate="Periodo: %{text}<br>SAIDI: %{y:.2f} min<extra></extra>",
                text=df["periodo"] if "periodo" in df.columns else df["periodo_orden"],
            )
        )
        fig.add_trace(
            go.Scatter(
                x=df["periodo_orden"],
                y=df["saifi_ciudad"],
                name="SAIFI (Frecuencia)",
                mode="lines+markers",
                line=dict(color="#ff5252", width=3),
                marker=dict(size=8, color="#ff5252", symbol="square"),
                hovertemplate="Periodo: %{text}<br>SAIFI: %{y:.4f}<extra></extra>",
                text=df["periodo"] if "periodo" in df.columns else df["periodo_orden"],
            )
        )
        fig.update_layout(
            title=dict(
                text="<b>Tendencia SAIDI / SAIFI por Mes</b>",
                font=dict(size=16, color="#ffffff")
            ),
            xaxis_title="Periodo",
            yaxis_title="Índice",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            legend=dict(
                orientation="h",
                yanchor="bottom",
                y=1.02,
                xanchor="right",
                x=1,
                bgcolor="rgba(0,0,0,0)"
            ),
            margin=dict(l=40, r=20, t=60, b=40),
            font=dict(family="Outfit, sans-serif", color="#9ca3af"),
            xaxis=dict(
                showgrid=True,
                gridcolor="rgba(255,255,255,0.05)",
                zeroline=False
            ),
            yaxis=dict(
                showgrid=True,
                gridcolor="rgba(255,255,255,0.05)",
                zeroline=True,
                zerolinecolor="rgba(255,255,255,0.1)"
            )
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
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Ranking Subestaciones (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            font=dict(family="Outfit, sans-serif")
        )
    else:
        # Map qualitative levels to beautiful theme colors
        color_map = {
            "NORMAL": "#00e676",      # Healthy
            "MEDIO": "#ffd600",       # Warning
            "ALTO": "#ff9100",        # High
            "CRITICO": "#ff5252",     # Critical
        }
        df = df.copy()
        df["color"] = df["nivel_desempeno"].map(color_map).fillna("#9ca3af")

        fig = go.Figure()
        fig.add_trace(
            go.Bar(
                y=df["subestacion"],
                x=df["saidi_promedio"],
                orientation="h",
                marker=dict(
                    color=df["color"],
                    line=dict(color="rgba(255,255,255,0.1)", width=1)
                ),
                text=df["saidi_promedio"].apply(lambda v: f" {v:.2f} min"),
                textposition="outside",
                hovertemplate="Subestación: %{y}<br>SAIDI Promedio: %{x:.2f} min<extra></extra>"
            )
        )
        fig.update_layout(
            title=dict(
                text="<b>Ranking SAIDI por Subestación</b>",
                font=dict(size=16, color="#ffffff")
            ),
            xaxis_title="SAIDI Promedio (min)",
            yaxis_title="",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            showlegend=False,
            margin=dict(l=120, r=40, t=60, b=40),
            yaxis=dict(
                autorange="reversed",
                showgrid=False
            ),
            xaxis=dict(
                showgrid=True,
                gridcolor="rgba(255,255,255,0.05)",
                zeroline=False
            ),
            font=dict(family="Outfit, sans-serif", color="#9ca3af")
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
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Mapa de Calor (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            font=dict(family="Outfit, sans-serif")
        )
    else:
        pivot = df.pivot_table(
            index="dia_semana",
            columns="hora",
            values="total_interrupciones",
            aggfunc="sum",
            fill_value=0,
        )
        
        # Reorder days of the week logically if they exist
        days_order = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        # Translate support (if database returns Spanish strings like Lunes, Martes...)
        spanish_days = ["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"]
        
        existing_days = pivot.index.tolist()
        if any(d in spanish_days for d in existing_days):
            order = [d for d in spanish_days if d in existing_days]
            pivot = pivot.reindex(order)
        elif any(d in days_order for d in existing_days):
            order = [d for d in days_order if d in existing_days]
            pivot = pivot.reindex(order)

        # High-contrast color gradient matching the theme
        colorscale = [
            [0.0, "rgba(20, 22, 32, 0.5)"],
            [0.2, "rgba(0, 229, 255, 0.3)"],
            [0.5, "rgba(255, 214, 0, 0.6)"],
            [0.8, "rgba(255, 145, 0, 0.8)"],
            [1.0, "rgba(255, 82, 82, 1.0)"]
        ]

        fig = go.Figure(
            data=go.Heatmap(
                z=pivot.values,
                x=pivot.columns,
                y=pivot.index,
                colorscale=colorscale,
                colorbar=dict(
                    title=dict(
                        text="Fallas",
                        font=dict(color="#9ca3af")
                    ),
                    thickness=15
                ),
                hovertemplate="Día: %{y}<br>Hora: %{x}:00<br>Interrupciones: %{z}<extra></extra>",
            )
        )
        fig.update_layout(
            title=dict(
                text="<b>Interrupciones por Hora y Día de la Semana</b>",
                font=dict(size=16, color="#ffffff")
            ),
            xaxis_title="Hora del día",
            yaxis_title="",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            margin=dict(l=80, r=20, t=60, b=50),
            xaxis=dict(
                dtick=2,
                showgrid=False
            ),
            yaxis=dict(
                showgrid=False
            ),
            font=dict(family="Outfit, sans-serif", color="#9ca3af")
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
    """
    if df is None or df.empty:
        fig = go.Figure()
        fig.update_layout(
            title="Auditoría de Errores (sin datos)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            font=dict(family="Outfit, sans-serif")
        )
    else:
        df = df.sort_values("fecha")
        fig = go.Figure()
        fig.add_trace(
            go.Scatter(
                x=df["fecha"],
                y=df["total_errores"],
                name="Total Errores",
                mode="lines+markers",
                fill="tozeroy",
                line=dict(color="#ff5252", width=3),
                fillcolor="rgba(255, 82, 82, 0.15)",
                marker=dict(size=6, color="#ff5252"),
                hovertemplate="Fecha: %{x}<br>Total Errores: %{y}<extra></extra>"
            )
        )
        fig.update_layout(
            title=dict(
                text="<b>Historial de Errores de Telemetría</b>",
                font=dict(size=16, color="#ffffff")
            ),
            xaxis_title="Fecha",
            yaxis_title="Total Errores",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
            margin=dict(l=45, r=20, t=60, b=40),
            font=dict(family="Outfit, sans-serif", color="#9ca3af"),
            xaxis=dict(
                showgrid=True,
                gridcolor="rgba(255,255,255,0.05)",
                zeroline=False
            ),
            yaxis=dict(
                showgrid=True,
                gridcolor="rgba(255,255,255,0.05)",
                zeroline=True,
                zerolinecolor="rgba(255,255,255,0.1)"
            ),
            showlegend=False
        )

    return dcc.Graph(
        id="error-trend-chart",
        figure=fig,
        config={"displayModeBar": False},
        className="chart-panel",
    )