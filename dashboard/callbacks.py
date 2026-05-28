"""
Dash callbacks for the Docker Dashboard.
Implements cross-filtering, drill-down chain, and interactive updates.
"""

from dash import callback, Input, Output, State, html, dash_table, callback_context
import dash_bootstrap_components as dbc

from dashboard.data import queries


# ==============================================================================
# KPI Update Callback
# ==============================================================================

@callback(
    Output("kpi-row", "children"),
    [
        Input("date-range", "start_date"),
        Input("date-range", "end_date"),
        Input("sector-filter", "value"),
        Input("criticality-filter", "value"),
        Input("med-toggle", "value"),
    ],
)
def update_kpis(start_date, end_date, sector, criticality, med_toggle):
    """
    Update KPI cards when any filter changes.
    Queries vw_saidi_saifi_mensual aggregated to city level with filters.
    Returns a dbc.Row of 4 KPI cards.
    """
    include_med = "excluir_med" not in med_toggle

    try:
        filters = {
            "start_date": start_date,
            "end_date": end_date,
            "sector": sector if sector != "ALL" else None,
            "criticality": criticality if criticality != "ALL" else None,
        }

        df = queries.get_saidi_saifi_mensual(filters)

        if df is None or df.empty:
            return _empty_kpi_row()

        # Aggregate to city level
        total_interrupciones = int(df["total_interrupciones"].sum())
        weighted_saidi = (df["saidi"] * df["total_clientes_afectados"]).sum() / max(df["total_clientes_afectados"].sum(), 1)
        weighted_saifi = (df["saifi"] * df["total_clientes_afectados"]).sum() / max(df["total_clientes_afectados"].sum(), 1)
        total_caidi = weighted_saidi / max(weighted_saifi, 1) if weighted_saifi > 0 else 0

        kpi_data = {
            "saidi": {"value": f"{weighted_saidi:.2f}", "delta": None, "icon": "bi bi-clock-fill"},
            "saifi": {"value": f"{weighted_saifi:.2f}", "delta": None, "icon": "bi bi-people-fill"},
            "caidi": {"value": f"{total_caidi:.2f}", "delta": None, "icon": "bi bi-stopwatch-fill"},
            "total_interrupciones": {"value": str(total_interrupciones), "delta": None, "icon": "bi bi-lightning-charge-fill"},
        }

        return _build_kpi_row(kpi_data)

    except Exception:
        return _empty_kpi_row()


def _empty_kpi_row():
    """Return a placeholder KPI row when no data is available."""
    return dbc.Row(
        [
            dbc.Col(_build_kpi_card("SAIDI Ciudad", "—", None, "bi bi-clock-fill"), width=3),
            dbc.Col(_build_kpi_card("SAIFI Ciudad", "—", None, "bi bi-people-fill"), width=3),
            dbc.Col(_build_kpi_card("CAIDI Ciudad", "—", None, "bi bi-stopwatch-fill"), width=3),
            dbc.Col(_build_kpi_card("Total Interrupciones", "—", None, "bi bi-lightning-charge-fill"), width=3),
        ],
        className="kpi-row g-4",
    )


def _build_kpi_row(kpi_data):
    """Build a KPI row from data dict."""
    return dbc.Row(
        [
            dbc.Col(_build_kpi_card(
                "SAIDI Ciudad",
                kpi_data["saidi"].get("value", "—"),
                kpi_data["saidi"].get("delta"),
                kpi_data["saidi"].get("icon", "bi bi-clock-fill"),
            ), width=3),
            dbc.Col(_build_kpi_card(
                "SAIFI Ciudad",
                kpi_data["saifi"].get("value", "—"),
                kpi_data["saifi"].get("delta"),
                kpi_data["saifi"].get("icon", "bi bi-people-fill"),
            ), width=3),
            dbc.Col(_build_kpi_card(
                "CAIDI Ciudad",
                kpi_data["caidi"].get("value", "—"),
                kpi_data["caidi"].get("delta"),
                kpi_data["caidi"].get("icon", "bi bi-stopwatch-fill"),
            ), width=3),
            dbc.Col(_build_kpi_card(
                "Total Interrupciones",
                kpi_data["total_interrupciones"].get("value", "—"),
                kpi_data["total_interrupciones"].get("delta"),
                kpi_data["total_interrupciones"].get("icon", "bi bi-lightning-charge-fill"),
            ), width=3),
        ],
        className="kpi-row g-4",
    )


def _build_kpi_card(title, value, delta=None, icon="bi bi-lightning-charge-fill"):
    """Build a single KPI card component."""
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
                html.Div(html.I(className=icon, style={"font-size": "1.5rem"}), className="kpi-icon"),
                html.H5(title, className="kpi-title"),
                html.H2(value, className="kpi-value"),
                delta_element,
            ],
        ),
        className="kpi-card",
    )


# ==============================================================================
# Trend Chart Callback
# ==============================================================================

@callback(
    Output("trend-chart", "figure"),
    [
        Input("date-range", "start_date"),
        Input("date-range", "end_date"),
        Input("sector-filter", "value"),
    ],
)
def update_trend(start_date, end_date, sector):
    """
    Update the trend line chart when date range or sector changes.
    Queries vw_tendencia_12_meses (no per-sector filtering in the view).
    """
    import plotly.graph_objects as go

    try:
        df = queries.get_tendencia_12_meses()

        if df is None or df.empty:
            fig = go.Figure()
            fig.update_layout(
                title="Tendencia SAIDI/SAIFI (sin datos)",
                template="plotly_dark",
                paper_bgcolor="rgba(0,0,0,0)",
                plot_bgcolor="rgba(0,0,0,0)",
            )
            return fig

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

        return fig

    except Exception:
        fig = go.Figure()
        fig.update_layout(
            title="Tendencia SAIDI/SAIFI (error)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
        )
        return fig


# ==============================================================================
# Ranking Chart Callback
# ==============================================================================

@callback(
    Output("ranking-chart", "figure"),
    [
        Input("date-range", "start_date"),
        Input("date-range", "end_date"),
        Input("sector-filter", "value"),
        Input("criticality-filter", "value"),
    ],
)
def update_ranking(start_date, end_date, sector, criticality):
    """
    Update the ranking bar chart when date range or filters change.
    Queries vw_ranking_subestaciones.
    """
    import plotly.graph_objects as go

    try:
        filters = {
            "sector": sector if sector != "ALL" else None,
            "criticality": criticality if criticality != "ALL" else None,
        }
        df = queries.get_ranking_subestaciones(filters)

        if df is None or df.empty:
            fig = go.Figure()
            fig.update_layout(
                title="Ranking Subestaciones (sin datos)",
                template="plotly_dark",
                paper_bgcolor="rgba(0,0,0,0)",
                plot_bgcolor="rgba(0,0,0,0)",
            )
            return fig

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

        return fig

    except Exception:
        fig = go.Figure()
        fig.update_layout(
            title="Ranking SAIDI (error)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
            plot_bgcolor="rgba(0,0,0,0)",
        )
        return fig


# ==============================================================================
# Heatmap Chart Callback
# ==============================================================================

@callback(
    Output("heatmap-chart", "figure"),
    [
        Input("date-range", "start_date"),
        Input("date-range", "end_date"),
        Input("sector-filter", "value"),
    ],
)
def update_heatmap(start_date, end_date, sector):
    """
    Update the heatmap chart when date range or sector changes.
    Queries vw_heatmap_interrupciones.
    """
    import plotly.graph_objects as go

    try:
        # Extract year/month from date range for filtering
        filters = {}
        if start_date:
            from datetime import datetime
            try:
                dt = datetime.strptime(start_date[:10], "%Y-%m-%d")
                filters["anio"] = dt.year
            except (ValueError, TypeError):
                pass

        df = queries.get_heatmap_interrupciones(filters if filters else None)

        if df is None or df.empty:
            fig = go.Figure()
            fig.update_layout(
                title="Mapa de Calor (sin datos)",
                template="plotly_dark",
                paper_bgcolor="rgba(0,0,0,0)",
            )
            return fig

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

        return fig

    except Exception:
        fig = go.Figure()
        fig.update_layout(
            title="Mapa de Calor (error)",
            template="plotly_dark",
            paper_bgcolor="rgba(0,0,0,0)",
        )
        return fig


# ==============================================================================
# Drill-down: Populate Subestacion Dropdown
# ==============================================================================

@callback(
    Output("drilldown-subestacion", "options"),
    Input("drilldown-subestacion", "search_value"),
)
def populate_subestaciones(search):
    """
    Populate the subestacion dropdown with distinct values from dim_red_electrica.
    Dash auto-search triggers this callback when user types in the dropdown.
    """
    try:
        df = queries.get_distinct_subestaciones()
        options = [{"label": s, "value": s} for s in df["subestacion"].tolist()]
        return options
    except Exception:
        return []


# ==============================================================================
# Drill-down: Populate Circuito Dropdown (based on subestacion)
# ==============================================================================

@callback(
    Output("drilldown-circuito", "options"),
    Input("drilldown-subestacion", "value"),
)
def populate_circuitos(subestacion):
    """
    Populate the circuito dropdown based on selected subestacion.
    When subestacion changes, this callback fires and filters circuitos.
    """
    try:
        df = queries.get_distinct_circuitos(subestacion)
        options = [{"label": c, "value": c} for c in df["circuito"].tolist()]
        return options
    except Exception:
        return []


# ==============================================================================
# Drill-down: Populate Transformador Dropdown (based on subestacion + circuito)
# ==============================================================================

@callback(
    Output("drilldown-transformador", "options"),
    [
        Input("drilldown-subestacion", "value"),
        Input("drilldown-circuito", "value"),
    ],
)
def populate_transformadores(subestacion, circuito):
    """
    Populate the transformador dropdown based on selected subestacion and circuito.
    """
    try:
        df = queries.get_distinct_transformadores(subestacion, circuito)
        options = [{"label": t, "value": t} for t in df["transformador"].tolist()]
        return options
    except Exception:
        return []


# ==============================================================================
# Drill-down: Update Table
# ==============================================================================

@callback(
    Output("drilldown-table", "data"),
    [
        Input("drilldown-subestacion", "value"),
        Input("drilldown-circuito", "value"),
        Input("drilldown-transformador", "value"),
        Input("date-range", "start_date"),
        Input("date-range", "end_date"),
        Input("med-toggle", "value"),
    ],
)
def update_drilldown_table(subestacion, circuito, transformador, start_date, end_date, med_toggle):
    """
    Update the drill-down table based on hierarchy selection and date range.
    Queries vw_saidi_saifi_mensual filtered by network hierarchy.
    """
    try:
        filters = {
            "start_date": start_date,
            "end_date": end_date,
        }
        if subestacion:
            filters["subestacion"] = subestacion
        if circuito:
            filters["circuito"] = circuito
        # transformador filter not in current query function — added via sub-query pattern if needed

        df = queries.get_saidi_saifi_mensual(filters)

        if df is None or df.empty:
            return []

        # Build response: aggregate at the appropriate level based on what's selected
        if transformador:
            level_cols = ["subestacion", "circuito", "transformador"]
        elif circuito:
            level_cols = ["subestacion", "circuito", "transformador"]
        elif subestacion:
            level_cols = ["subestacion", "circuito"]
        else:
            level_cols = ["subestacion"]

        agg = df.groupby(level_cols).agg(
            total_interrupciones=("total_interrupciones", "sum"),
            saidi=("saidi", "mean"),
            saifi=("saifi", "mean"),
            caidi=("caidi", "mean"),
        ).reset_index()

        # Compute CAIDI if not present
        if "caidi" not in agg.columns or agg["caidi"].isna().all():
            agg["caidi"] = agg["saidi"] / agg["saifi"].replace(0, float("nan"))

        return agg.to_dict("records")

    except Exception:
        return []


# ==============================================================================
# Drill-down: Update Breadcrumb
# ==============================================================================

@callback(
    Output("drilldown-breadcrumb", "children"),
    [
        Input("drilldown-subestacion", "value"),
        Input("drilldown-circuito", "value"),
        Input("drilldown-transformador", "value"),
    ],
)
def update_breadcrumb(subestacion, circuito, transformador):
    """
    Update the breadcrumb navigation based on current drill-down selection.
    Builds: Ciudad > [Subestación] > [Circuito] > [Transformador]
    """
    items = [dbc.BreadcrumbItem("Ciudad", href="#", className="breadcrumb-link")]

    if subestacion:
        items.append(dbc.BreadcrumbItem("", className="separator"))
        items.append(dbc.BreadcrumbItem(subestacion, href="#", className="breadcrumb-link"))

    if circuito:
        items.append(dbc.BreadcrumbItem("", className="separator"))
        items.append(dbc.BreadcrumbItem(circuito, href="#", className="breadcrumb-link"))

    if transformador:
        items.append(dbc.BreadcrumbItem("", className="separator"))
        items.append(dbc.BreadcrumbItem(transformador, href="#", className="breadcrumb-link"))

    # Mark last item as active
    if items:
        # Remove active from all first
        for item in items:
            item.active = False
        # Set last non-separator as active
        for item in reversed(items):
            if item.className != "separator":
                item.active = True
                break

    return items


# ==============================================================================
# Ops: Refresh ELT Table + Error Chart
# ==============================================================================

@callback(
    [Output("elt-status-table", "data"), Output("error-trend-chart", "figure")],
    [Input("refresh-ops", "n_clicks")],
    prevent_initial_call=True,
)
def update_ops(n_clicks):
    """
    Update the ELT status table and error audit chart on refresh button click.
    Queries vw_monitoreo_elt and vw_auditoria_errores.
    """
    import plotly.graph_objects as go

    try:
        elt_df = queries.get_monitoreo_elt()
        error_df = queries.get_auditoria_errores()

        # ELT table data
        elt_data = elt_df.to_dict("records") if elt_df is not None and not elt_df.empty else []

        # Error chart figure
        if error_df is None or error_df.empty:
            fig = go.Figure()
            fig.update_layout(
                title="Auditoría de Errores (sin datos)",
                template="plotly_dark",
                paper_bgcolor="rgba(0,0,0,0)",
                plot_bgcolor="rgba(0,0,0,0)",
            )
        else:
            error_df = error_df.sort_values("fecha")
            fig = go.Figure()
            fig.add_trace(
                go.Scatter(
                    x=error_df["fecha"],
                    y=error_df["total_errores"],
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

        return elt_data, fig

    except Exception:
        return [], go.Figure()