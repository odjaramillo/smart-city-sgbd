"""
SQLAlchemy query functions for the Docker Dashboard.
Each function returns a pandas DataFrame from the corresponding analytic view.
Connection and caching are managed at module level.
"""

import os
from typing import Optional

from flask_caching import Cache
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

_engine: Optional[Engine] = None

_cache = Cache()


def get_engine() -> Engine:
    global _engine
    if _engine is not None:
        return _engine

    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        raise RuntimeError("DATABASE_URL environment variable is not set")

    _engine = create_engine(
        database_url,
        pool_size=5,
        max_overflow=10,
        pool_pre_ping=True,
    )
    return _engine


def init_cache(app):
    _cache.init_app(app, config={
        "CACHE_TYPE": "SimpleCache",
        "CACHE_DEFAULT_TIMEOUT": 300,
    })


def get_cache() -> Cache:
    return _cache


def _read_sql(query: str, params: Optional[dict] = None) -> "pd.DataFrame":
    import pandas as pd
    engine = get_engine()
    with engine.connect() as conn:
        return pd.read_sql(text(query), conn, params=params)


def _cached_read_sql(cache_key: str, query: str, params: Optional[dict] = None) -> "pd.DataFrame":
    import pandas as pd

    cache = get_cache()
    cached = cache.get(cache_key)
    if cached is not None:
        return cached

    result = _read_sql(query, params)
    cache.set(cache_key, result)
    return result


def get_saidi_saifi_mensual(filters: Optional[dict] = None) -> "pd.DataFrame":
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


def get_saidi_saifi_con_med(filters: Optional[dict] = None) -> "pd.DataFrame":
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


def get_tendencia_12_meses() -> "pd.DataFrame":
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


def get_ranking_subestaciones(filters: Optional[dict] = None) -> "pd.DataFrame":
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


def get_heatmap_interrupciones(filters: Optional[dict] = None) -> "pd.DataFrame":
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


def get_auditoria_errores(filters: Optional[dict] = None) -> "pd.DataFrame":
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


def get_monitoreo_elt() -> "pd.DataFrame":
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


def get_distinct_sectors() -> "pd.DataFrame":
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
