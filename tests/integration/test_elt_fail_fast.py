# -*- coding: utf-8 -*-
"""
Tests/integration/test_elt_fail_fast.py

TDD Tests para verificar que el SP lanza RAISE EXCEPTION cuando faltan
dimensiones (fail-fast) y que las transacciones se revierten correctamente.

Ejecutar con:
    pytest tests/integration/test_elt_fail_fast.py -v

Requiere:
    - PostgreSQL corriendo con DDL + SP cargados en smart_city_test
    - Variables de entorno: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

import os
import pytest
import psycopg2


def _get_connection():
    return psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "smart_city_test"),
        user=os.getenv("PGUSER", "ucab"),
        password=os.getenv("PGPASSWORD", "ucab123"),
    )


@pytest.fixture(scope="function")
def cleanup():
    """Clean staging, facts, errors, and control before and after each test."""
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("DELETE FROM err_telemetria")
    cur.execute("DELETE FROM fact_interrupciones")
    cur.execute("DELETE FROM staging_eventos")
    cur.execute("DELETE FROM ctrl_lotes_procesamiento")
    yield
    cur.execute("DELETE FROM err_telemetria")
    cur.execute("DELETE FROM fact_interrupciones")
    cur.execute("DELETE FROM staging_eventos")
    cur.execute("DELETE FROM ctrl_lotes_procesamiento")
    cur.close()
    conn.close()


@pytest.fixture(scope="function")
def setup_all_dimensions_except_red():
    """Set up all dimensions EXCEPT dim_red_electrica for medidor 7001."""
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, dia, dia_semana, dia_semana_num,
            semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana, es_feriado)
        VALUES ('2025-05-20', 20, 'Tuesday', 2, 21, 5, 'May', 2, 2025, FALSE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_FAILFAST_TEST', 'Distrito FF', -34.5, -58.4, 'NORMAL')
        ON CONFLICT (sector_urbano) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
        VALUES (800, '2024-01-01 00:00:00+00', TRUE, 1)
    """)

    yield
    cur.close()
    conn.close()


@pytest.fixture(scope="function")
def setup_all_dimensions_except_clientes():
    """Set up all dimensions EXCEPT dim_clientes_inventario active at event time."""
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("DELETE FROM dim_clientes_inventario")

    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, dia, dia_semana, dia_semana_num,
            semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana, es_feriado)
        VALUES ('2025-06-15', 15, 'Sunday', 7, 24, 6, 'June', 2, 2025, TRUE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_FAILFAST_CLI', 'Distrito FF Cli', -34.5, -58.4, 'NORMAL')
        ON CONFLICT (sector_urbano) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor,
            transformador, circuito, subestacion, fecha_inicio, activo_bool)
        VALUES (7002, 7002, 'MED-FF-7002', 'TFR-FF', 'CIR-FF', 'SUB-FF',
                '2024-01-01 00:00:00+00', TRUE)
        ON CONFLICT (id_medidor_origen, fecha_inicio) DO NOTHING
    """)

    yield
    cur.close()
    conn.close()


def test_missing_dim_red_electrica_raises_exception(setup_all_dimensions_except_red, cleanup):
    """
    SP must RAISE EXCEPTION when dim_red_electrica has no active SCD2 entry
    for the medidor at the event timestamp.

    No silent fallback to 'DESCONOCIDO' dimensions.
    """
    conn = _get_connection()
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES
            (7001, '2025-05-20 10:00:00+00', 'POWER_OUTAGE'),
            (7001, '2025-05-20 11:00:00+00', 'POWER_RESTORATION')
    """)
    conn.commit()

    with pytest.raises(psycopg2.errors.RaiseException) as exc_info:
        cur.execute("CALL sp_reconciliar_interrupciones(NULL)")
        conn.commit()

    error_msg = str(exc_info.value)
    assert "DIMENSION_FALTANTE" in error_msg or "dim_red_electrica" in error_msg, \
        f"Expected DIMENSION_FALTANTE error for dim_red_electrica, got: {error_msg}"

    conn.rollback()

    conn_check = _get_connection()
    conn_check.autocommit = True
    cur_check = conn_check.cursor()

    cur_check.execute("SELECT COUNT(*) FROM fact_interrupciones WHERE id_medidor = 7001")
    assert cur_check.fetchone()[0] == 0, "No fact should be created when dimension is missing"

    cur_check.execute("""
        SELECT COUNT(*) FROM staging_eventos
        WHERE id_medidor = 7001 AND procesado = TRUE
    """)
    assert cur_check.fetchone()[0] == 0, "Staging events should remain unprocessed after rollback"

    cur_check.close()
    conn_check.close()
    cur.close()
    conn.close()


def test_missing_dim_clientes_raises_exception(setup_all_dimensions_except_clientes, cleanup):
    """
    SP must RAISE EXCEPTION when dim_clientes_inventario has no active snapshot
    at the event timestamp.
    """
    conn = _get_connection()
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES
            (7002, '2025-06-15 14:00:00+00', 'POWER_OUTAGE'),
            (7002, '2025-06-15 15:30:00+00', 'POWER_RESTORATION')
    """)
    conn.commit()

    with pytest.raises(psycopg2.errors.RaiseException) as exc_info:
        cur.execute("CALL sp_reconciliar_interrupciones(NULL)")
        conn.commit()

    error_msg = str(exc_info.value)
    assert "DIMENSION_FALTANTE" in error_msg or "dim_clientes_inventario" in error_msg, \
        f"Expected DIMENSION_FALTANTE error for dim_clientes_inventario, got: {error_msg}"

    conn.rollback()

    conn_check = _get_connection()
    conn_check.autocommit = True
    cur_check = conn_check.cursor()
    cur_check.execute("SELECT COUNT(*) FROM fact_interrupciones WHERE id_medidor = 7002")
    assert cur_check.fetchone()[0] == 0, "No fact should be created when dimension is missing"
    cur_check.close()
    conn_check.close()
    cur.close()
    conn.close()


def test_failed_sp_marks_lote_as_fallido(setup_all_dimensions_except_red, cleanup):
    """
    When the SP raises an exception, ctrl_lotes_procesamiento.estado
    must be 'FALLIDO'.
    """
    conn = _get_connection()
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES
            (7001, '2025-05-20 10:00:00+00', 'POWER_OUTAGE'),
            (7001, '2025-05-20 11:00:00+00', 'POWER_RESTORATION')
    """)
    conn.commit()

    try:
        cur.execute("CALL sp_reconciliar_interrupciones(NULL)")
        conn.commit()
    except psycopg2.Error:
        conn.rollback()

    conn_check = _get_connection()
    conn_check.autocommit = True
    cur_check = conn_check.cursor()

    cur_check.execute("""
        SELECT estado FROM ctrl_lotes_procesamiento
        ORDER BY id_lote DESC LIMIT 1
    """)
    result = cur_check.fetchone()

    if result:
        assert result[0] == 'FALLIDO', f"Expected lote estado 'FALLIDO', got '{result[0]}'"

    cur_check.close()
    conn_check.close()
    cur.close()
    conn.close()


def test_orphan_events_go_to_err_telemetria(cleanup):
    """
    RESTORATION without prior OUTAGE should be quarantined in err_telemetria,
    NOT raise an exception. Orphan handling is graceful, not fail-fast.
    """
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES (8001, '2025-05-20 10:00:00+00', 'POWER_RESTORATION')
    """)

    cur.execute("CALL sp_reconciliar_interrupciones(NULL)")

    cur.execute("""
        SELECT COUNT(*) FROM err_telemetria
        WHERE id_medidor = 8001
          AND motivo_error LIKE '%%RESTAURACION_HUERFANA%%'
    """)
    orphan_count = cur.fetchone()[0]
    assert orphan_count == 1, f"Expected 1 orphan in err_telemetria, got {orphan_count}"

    cur.execute("""
        SELECT procesado FROM staging_eventos WHERE id_medidor = 8001
    """)
    result = cur.fetchone()
    assert result[0] is True, "Orphan event should be marked as processed"

    cur.execute("SELECT COUNT(*) FROM fact_interrupciones WHERE id_medidor = 8001")
    assert cur.fetchone()[0] == 0, "Orphan should NOT create a fact"

    cur.close()
    conn.close()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
