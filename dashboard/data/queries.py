"""
SQLAlchemy query functions for the Docker Dashboard.
Each function returns a pandas DataFrame from the corresponding analytic view.
Connection and caching are managed at module level.
"""

import os
from typing import Optional

from dotenv import load_dotenv
from flask_caching import Cache
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

load_dotenv()

# ==============================================================================
# Connection Setup
# ==============================================================================

def get_engine() -> Engine:
    """
    Create SQLAlchemy engine using DATABASE_URL from environment.
    Connection pooling: pool_size=5, max_overflow=10.
    """
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        raise RuntimeError("DATABASE_URL environment variable is not set")

    return create_engine(
        database_url,
        pool_size=5,
        max_overflow=10,
        pool_pre_ping=True,
    )


# ==============================================================================
# Cache Setup
# ==============================================================================

_cache = Cache()


def init_cache(app):
    """Initialize Flask-Caching with SimpleCache and 5-minute TTL."""
    _cache.init_app(app, config={
        "CACHE_TYPE": "SimpleCache",
        "CACHE_DEFAULT_TIMEOUT": 300,  # 5 minutes
    })


def get_cache() -> Cache:
    return _cache


# ==============================================================================
# Base Query Executor
# ==============================================================================

def _read_sql(query: str, params: Optional[dict] = None) -> "pd.DataFrame":
    """
    Execute a SQL query and return a DataFrame.
    Import pandas locally to avoid circular imports.
    """
    import pandas as pd
    engine = get_engine()
    with engine.connect() as conn:
        return pd.read_sql(text(query), conn, params=params)


def _cached_read_sql(cache_key: str, query: str, params: Optional[dict] = None) -> "pd.DataFrame":
    """
    Execute a cached SQL query. Cache expires after 5 minutes.
    Returns the cached DataFrame if available.
    """
    import pandas as pd

    cache = get_cache()
    cached = cache.get(cache_key)
    if cached is not None:
        return cached

    result = _read_sql(query, params)
    cache.set(cache_key, result)
    return result


# ==============================================================================
# View: vw_saidi_saifi_mensual
# Monthly SAIDI/SAIFI/CAIDI with network hierarchy.
# Filters: subestacion, circuito, anio, mes, sector, criticality
# ==============================================================================

def get_saidi_saifi_mensual(filters: Optional[dict] = None) -> "pd.DataFrame":
    """
    Query vw_saidi_saifi_mensual with optional filters.

    Filters supported:
        - subestacion (str): filter by subestacion name
        - circuito (str): filter by circuito name
        - anio (int): filter by year
        - mes (int): filter by month number (1-12)
        - sector (str): filter by sector_urbano from dim_geografia_urbana
        - criticality (str): filter by nivel_criticidad
    """
    import pandas as pd

    base_query = """
        SELECT
            subestacion,
            circuito,
            transformador,
            anio,
            mes,
            nombre_mes,
            trimestre,
            periodo,
            total_interrupciones,
            suma_duracion_minutos,
            suma_minutos_cliente,
            total_clientes_afectados,
            total_clientes_servidos,
            saidi,
            saifi,
            caidi,
            fecha_consulta
        FROM vw_saidi_saifi_mensual
        WHERE subestacion IS NOT NULL
    """

    conditions = []
    params = {}

    if filters:
        f = filters
        if f.get("subestacion"):
            conditions.append("subestacion = :subestacion")
            params["subestacion"] = f["subestacion"]
        if f.get("circuito"):
            conditions.append("circuito = :circuito")
            params["circuito"] = f["circuito"]
        if f.get("anio"):
            conditions.append("anio = :anio")
            params["anio"] = f["anio"]
        if f.get("mes"):
            conditions.append("mes = :mes")
            params["mes"] = f["mes"]
        if f.get("sector"):
            conditions.append("""
                subestacion IN (
                    SELECT dre.subestacion
                    FROM dim_red_electrica dre
                    JOIN dim_geografia_urbana dgu ON dre.subestacion = dgu.distrito
                    WHERE dgu.sector_urbano = :sector
                )
            """)
            params["sector"] = f["sector"]
        if f.get("criticality"):
            conditions.append("""
                subestacion IN (
                    SELECT dre.subestacion
                    FROM dim_red_electrica dre
                    JOIN dim_geografia_urbana dgu ON dre.subestacion = dgu.distrito
                    WHERE dgu.nivel_criticidad = :criticality
                )
            """)
            params["criticality"] = f["criticality"]

    if conditions:
        base_query += " AND " + " AND ".join(conditions)

    base_query += " ORDER BY anio DESC, mes DESC, subestacion"

    return pd.read_sql(text(base_query), get_engine().connect(), params=params)


# ==============================================================================
# View: vw_saidi_saifi_con_med
# Daily detail with MED flag for drill-down.
# Filters: start_date, end_date, subestacion, circuito
# ==============================================================================

def get_saidi_saifi_con_med(filters: Optional[dict] = None) -> "pd.DataFrame":
    """
    Query vw_saidi_saifi_con_med for daily detail with MED flag.

    Filters supported:
        - start_date (str): start date (YYYY-MM-DD)
        - end_date (str): end date (YYYY-MM-DD)
        - subestacion (str): filter by subestacion name
        - circuito (str): filter by circuito name
    """
    import pandas as pd

    query = """
        SELECT
            anio,
            mes,
            nombre_mes,
            trimestre,
            dia,
            fecha,
            total_interrupciones,
            suma_minutos_cliente,
            total_clientes_servidos,
            saidi_diario,
            saifi_diario,
            umbral_med,
            es_med
        FROM vw_saidi_saifi_con_med
        WHERE 1=1
    """

    conditions = []
    params = {}

    if filters:
        f = filters
        if f.get("start_date"):
            conditions.append("fecha >= :start_date")
            params["start_date"] = f["start_date"]
        if f.get("end_date"):
            conditions.append("fecha <= :end_date")
            params["end_date"] = f["end_date"]
        if f.get("subestacion"):
            conditions.append("""
                fecha IN (
                    SELECT DISTINCT dt.timestamp_completo::DATE
                    FROM fact_interrupciones fi
                    JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
                    JOIN dim_red_electrica dre ON fi.sk_red_electrica = dre.sk_red_electrica
                    WHERE dre.subestacion = :subestacion
                )
            """)
            params["subestacion"] = f["subestacion"]
        if f.get("circuito"):
            conditions.append("""
                fecha IN (
                    SELECT DISTINCT dt.timestamp_completo::DATE
                    FROM fact_interrupciones fi
                    JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
                    JOIN dim_red_electrica dre ON fi.sk_red_electrica = dre.sk_red_electrica
                    WHERE dre.circuito = :circuito
                )
            """)
            params["circuito"] = f["circuito"]

    if conditions:
        query += " AND " + " AND ".join(conditions)

    query += " ORDER BY fecha DESC"

    return pd.read_sql(text(query), get_engine().connect(), params=params)


# ==============================================================================
# View: vw_tendencia_12_meses
# Trend line chart data. Cached (expensive aggregation).
# No filters — always returns last 24 months.
# ==============================================================================

def get_tendencia_12_meses() -> "pd.DataFrame":
    """
    Query vw_tendencia_12_meses for trend line chart.
    Returns last 24 months of city-level SAIDI/SAIFI data.
    This view is cached for 5 minutes.
    """
    return _cached_read_sql(
        "tendencia_12_meses",
        """
        SELECT
            anio,
            mes,
            nombre_mes,
            trimestre,
            periodo,
            periodo_orden,
            total_interrupciones,
            total_clientes_afectados,
            saidi_ciudad,
            saifi_ciudad,
            variacion_saidi_pct
        FROM vw_tendencia_12_meses
        ORDER BY periodo_orden ASC
        """
    )


# ==============================================================================
# View: vw_ranking_subestaciones
# Bar chart showing substation performance ranking. Cached.
# Filters: sector, criticality
# ==============================================================================

def get_ranking_subestaciones(filters: Optional[dict] = None) -> "pd.DataFrame":
    """
    Query vw_ranking_subestaciones for bar chart.

    Filters supported:
        - sector (str): filter by sector_urbano
        - criticality (str): filter by nivel_criticidad
    """
    import pandas as pd

    query = """
        SELECT
            ranking,
            subestacion,
            meses_con_datos,
            saidi_promedio,
            saifi_promedio,
            caidi_promedio,
            total_interrupciones_acum,
            saidi_promedio_ciudad,
            delta_vs_ciudad,
            nivel_desempeno
        FROM vw_ranking_subestaciones
        WHERE 1=1
    """

    conditions = []
    params = {}

    if filters:
        f = filters
        if f.get("sector"):
            conditions.append("""
                subestacion IN (
                    SELECT dre.subestacion
                    FROM dim_red_electrica dre
                    JOIN dim_geografia_urbana dgu ON dre.subestacion = dgu.distrito
                    WHERE dgu.sector_urbano = :sector
                )
            """)
            params["sector"] = f["sector"]
        if f.get("criticality"):
            conditions.append("""
                subestacion IN (
                    SELECT dre.subestacion
                    FROM dim_red_electrica dre
                    JOIN dim_geografia_urbana dgu ON dre.subestacion = dgu.distrito
                    WHERE dgu.nivel_criticidad = :criticality
                )
            """)
            params["criticality"] = f["criticality"]

    if conditions:
        query += " AND " + " AND ".join(conditions)

    query += " ORDER BY ranking ASC"

    return pd.read_sql(text(query), get_engine().connect(), params=params)


# ==============================================================================
# View: vw_heatmap_interrupciones
# Heatmap matrix: hour × day-of-week. Cached.
# Filters: anio, mes
# ==============================================================================

def get_heatmap_interrupciones(filters: Optional[dict] = None) -> "pd.DataFrame":
    """
    Query vw_heatmap_interrupciones for heatmap matrix.

    Filters supported:
        - anio (int): filter by year
        - mes (int): filter by month number (1-12)
    """
    import pandas as pd

    query = """
        SELECT
            hora,
            dia_semana,
            dia_semana_num,
            franja_horaria,
            total_interrupciones,
            duracion_promedio,
            duracion_total
        FROM vw_heatmap_interrupciones
        WHERE 1=1
    """

    params = {}
    conditions = []

    if filters:
        f = filters
        if f.get("anio"):
            conditions.append("""
                hora IN (
                    SELECT DISTINCT dt.hora
                    FROM fact_interrupciones fi
                    JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
                    WHERE dt.anio = :anio
                )
            """)
            params["anio"] = f["anio"]
        if f.get("mes"):
            conditions.append("""
                hora IN (
                    SELECT DISTINCT dt.hora
                    FROM fact_interrupciones fi
                    JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
                    WHERE dt.anio = EXTRACT(YEAR FROM NOW())::SMALLINT
                      AND dt.mes = :mes
                )
            """)
            params["mes"] = f["mes"]

    if conditions:
        query += " AND " + " AND ".join(conditions)

    query += " ORDER BY dia_semana_num, hora"

    return pd.read_sql(text(query), get_engine().connect(), params=params)


# ==============================================================================
# View: vw_auditoria_errores
# Error audit panel for data quality monitoring.
# Filters: start_date, end_date, motivo_error
# ==============================================================================

def get_auditoria_errores(filters: Optional[dict] = None) -> "pd.DataFrame":
    """
    Query vw_auditoria_errores for error audit panel.

    Filters supported:
        - start_date (str): start date (YYYY-MM-DD)
        - end_date (str): end date (YYYY-MM-DD)
        - motivo_error (str): filter by error reason
    """
    import pandas as pd

    query = """
        SELECT
            fecha,
            motivo_error,
            total_errores,
            medidores_afectados,
            resueltos,
            pendientes
        FROM vw_auditoria_errores
        WHERE 1=1
    """

    conditions = []
    params = {}

    if filters:
        f = filters
        if f.get("start_date"):
            conditions.append("fecha >= :start_date")
            params["start_date"] = f["start_date"]
        if f.get("end_date"):
            conditions.append("fecha <= :end_date")
            params["end_date"] = f["end_date"]
        if f.get("motivo_error"):
            conditions.append("motivo_error = :motivo_error")
            params["motivo_error"] = f["motivo_error"]

    if conditions:
        query += " AND " + " AND ".join(conditions)

    query += " ORDER BY fecha DESC, total_errores DESC"

    return pd.read_sql(text(query), get_engine().connect(), params=params)


# ==============================================================================
# View: vw_monitoreo_elt
# Operations dashboard for ELT pipeline monitoring.
# No filters — returns latest batches.
# ==============================================================================

def get_monitoreo_elt() -> "pd.DataFrame":
    """
    Query vw_monitoreo_elt for ops dashboard.
    Returns recent ELT processing batches.
    """
    import pandas as pd

    return pd.read_sql(
        text("""
            SELECT
                id_lote,
                fecha_inicio,
                fecha_fin,
                fecha_ejecucion,
                total_eventos,
                total_hechos,
                total_huerfanos,
                total_transitorios,
                estado,
                duracion_segundos,
                tasa_conversion_pct,
                tasa_error_pct
            FROM vw_monitoreo_elt
            ORDER BY id_lote DESC
            LIMIT 100
        """),
        get_engine().connect()
    )


# ==============================================================================
# Dimension Lookups (for filter dropdowns)
# ==============================================================================

def get_distinct_sectors() -> "pd.DataFrame":
    """
    Query distinct sector_urbano values from dim_geografia_urbana
    for filter dropdown.
    """
    import pandas as pd

    return pd.read_sql(
        text("""
            SELECT DISTINCT sector_urbano
            FROM dim_geografia_urbana
            WHERE sector_urbano IS NOT NULL
            ORDER BY sector_urbano
        """),
        get_engine().connect()
    )


def get_distinct_criticality() -> "pd.DataFrame":
    """
    Query distinct nivel_criticidad values from dim_geografia_urbana
    for criticality filter dropdown.
    """
    import pandas as pd

    return pd.read_sql(
        text("""
            SELECT DISTINCT nivel_criticidad
            FROM dim_geografia_urbana
            WHERE nivel_criticidad IS NOT NULL
            ORDER BY nivel_criticidad
        """),
        get_engine().connect()
    )


def get_distinct_subestaciones() -> "pd.DataFrame":
    """
    Query distinct subestacion values from dim_red_electrica
    for drill-down navigation.
    """
    import pandas as pd

    return pd.read_sql(
        text("""
            SELECT DISTINCT subestacion
            FROM dim_red_electrica
            WHERE subestacion IS NOT NULL
              AND activo_bool = TRUE
            ORDER BY subestacion
        """),
        get_engine().connect()
    )


def get_distinct_circuitos(subestacion: Optional[str] = None) -> "pd.DataFrame":
    """
    Query distinct circuito values from dim_red_electrica,
    optionally filtered by subestacion.
    """
    import pandas as pd

    if subestacion:
        return pd.read_sql(
            text("""
                SELECT DISTINCT circuito
                FROM dim_red_electrica
                WHERE subestacion = :subestacion
                  AND activo_bool = TRUE
                ORDER BY circuito
            """),
            get_engine().connect(),
            params={"subestacion": subestacion}
        )

    return pd.read_sql(
        text("""
            SELECT DISTINCT circuito
            FROM dim_red_electrica
            WHERE circuito IS NOT NULL
              AND activo_bool = TRUE
            ORDER BY circuito
        """),
        get_engine().connect()
    )


def get_distinct_transformadores(
    subestacion: Optional[str] = None,
    circuito: Optional[str] = None
) -> "pd.DataFrame":
    """
    Query distinct transformador values from dim_red_electrica,
    optionally filtered by subestacion and/or circuito.
    """
    import pandas as pd

    params = {}
    conditions = ["activo_bool = TRUE"]

    if subestacion:
        conditions.append("subestacion = :subestacion")
        params["subestacion"] = subestacion
    if circuito:
        conditions.append("circuito = :circuito")
        params["circuito"] = circuito

    query = """
        SELECT DISTINCT transformador
        FROM dim_red_electrica
        WHERE """ + " AND ".join(conditions) + """
        ORDER BY transformador
    """

    return pd.read_sql(text(query), get_engine().connect(), params=params)