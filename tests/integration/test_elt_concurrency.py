# -*- coding: utf-8 -*-
"""
Tests/integration/test_elt_concurrency.py

TDD Tests para verificar que FOR UPDATE SKIP LOCKED previene
procesamiento duplicado cuando dos instancias del SP corren en paralelo.

Ejecutar con:
    pytest tests/integration/test_elt_concurrency.py -v

Requiere:
    - PostgreSQL corriendo con DDL + SP cargados en smart_city_test
    - Variables de entorno: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

import os
import threading
import time
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
def setup_dimensions():
    """Insert dimension rows required by the SP (fail-fast lookups)."""
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, dia, dia_semana, dia_semana_num,
            semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana, es_feriado)
        VALUES ('2025-03-15', 15, 'Saturday', 6, 11, 3, 'March', 1, 2025, TRUE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_CONC_TEST', 'Distrito Conc', -34.6, -58.38, 'NORMAL')
        ON CONFLICT (sector_urbano) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor,
            transformador, circuito, subestacion, fecha_inicio, activo_bool)
        VALUES (5001, 5001, 'MED-CONC-5001', 'TFR-CONC', 'CIR-CONC', 'SUB-CONC',
                '2024-01-01 00:00:00+00', TRUE)
        ON CONFLICT (id_medidor_origen, fecha_inicio) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
        VALUES (500, '2024-01-01 00:00:00+00', TRUE, 1)
    """)

    yield
    cur.close()
    conn.close()


@pytest.fixture(scope="function")
def cleanup_staging_and_facts():
    """Clean staging and facts before and after each test."""
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


def test_concurrent_sp_no_duplicates(setup_dimensions, cleanup_staging_and_facts):
    """
    Two concurrent SP executions must NOT create duplicate facts.

    FOR UPDATE SKIP LOCKED ensures each instance locks a disjoint set of
    staging rows. Even if both start simultaneously, only one processes
    each OUTAGE→RESTORATION pair.
    """
    conn_setup = _get_connection()
    conn_setup.autocommit = True
    cur_setup = conn_setup.cursor()

    cur_setup.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES
            (5001, '2025-03-15 10:00:00+00', 'POWER_OUTAGE'),
            (5001, '2025-03-15 11:30:00+00', 'POWER_RESTORATION')
    """)

    cur_setup.close()
    conn_setup.close()

    results = {"thread1": None, "thread2": None, "errors": []}

    def run_sp(thread_name):
        try:
            conn = _get_connection()
            conn.autocommit = True
            cur = conn.cursor()
            cur.execute("CALL sp_reconciliar_interrupciones(NULL)")
            cur.close()
            conn.close()
            results[thread_name] = "ok"
        except Exception as e:
            results["errors"].append((thread_name, str(e)))
            results[thread_name] = "error"

    t1 = threading.Thread(target=run_sp, args=("thread1",))
    t2 = threading.Thread(target=run_sp, args=("thread2",))

    t1.start()
    t2.start()
    t1.join(timeout=30)
    t2.join(timeout=30)

    conn_check = _get_connection()
    conn_check.autocommit = True
    cur_check = conn_check.cursor()

    cur_check.execute("""
        SELECT COUNT(*) FROM fact_interrupciones
        WHERE id_medidor = 5001
          AND timestamp_inicio = '2025-03-15 10:00:00+00'
    """)
    fact_count = cur_check.fetchone()[0]

    cur_check.execute("""
        SELECT COUNT(*) FROM ctrl_lotes_procesamiento
        WHERE estado = 'COMPLETADO'
    """)
    completed_lots = cur_check.fetchone()[0]

    cur_check.execute("""
        SELECT COUNT(*) FROM staging_eventos
        WHERE id_medidor = 5001 AND procesado = TRUE
    """)
    processed_count = cur_check.fetchone()[0]

    cur_check.close()
    conn_check.close()

    assert fact_count == 1, f"Expected exactly 1 fact, got {fact_count} (duplicate processing!)"
    assert processed_count == 2, f"Expected 2 processed staging events, got {processed_count}"


def test_skip_locked_partitions_work(setup_dimensions, cleanup_staging_and_facts):
    """
    When one transaction holds locks on staging rows, a second concurrent
    SP call should skip those rows and process only unlocked ones.
    """
    conn_lock = _get_connection()
    cur_lock = conn_lock.cursor()

    conn_setup = _get_connection()
    conn_setup.autocommit = True
    cur_setup = conn_setup.cursor()

    cur_setup.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES
            (5001, '2025-03-15 10:00:00+00', 'POWER_OUTAGE'),
            (5001, '2025-03-15 11:30:00+00', 'POWER_RESTORATION'),
            (5002, '2025-03-15 10:00:00+00', 'POWER_OUTAGE'),
            (5002, '2025-03-15 11:00:00+00', 'POWER_RESTORATION')
    """)

    cur_setup.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor,
            transformador, circuito, subestacion, fecha_inicio, activo_bool)
        VALUES (5002, 5002, 'MED-CONC-5002', 'TFR-CONC', 'CIR-CONC', 'SUB-CONC',
                '2024-01-01 00:00:00+00', TRUE)
        ON CONFLICT (id_medidor_origen, fecha_inicio) DO NOTHING
    """)

    cur_setup.close()
    conn_setup.close()

    cur_lock.execute("BEGIN")
    cur_lock.execute("""
        SELECT id_evento FROM staging_eventos
        WHERE procesado = FALSE AND id_medidor = 5001
        FOR UPDATE SKIP LOCKED
    """)
    locked_ids = cur_lock.fetchall()

    conn_sp = _get_connection()
    conn_sp.autocommit = True
    cur_sp = conn_sp.cursor()
    cur_sp.execute("CALL sp_reconciliar_interrupciones(NULL)")
    cur_sp.close()
    conn_sp.close()

    conn_check = _get_connection()
    conn_check.autocommit = True
    cur_check = conn_check.cursor()

    cur_check.execute("""
        SELECT COUNT(*) FROM fact_interrupciones
        WHERE id_medidor = 5002
    """)
    medidor_5002_facts = cur_check.fetchone()[0]

    cur_check.execute("""
        SELECT COUNT(*) FROM fact_interrupciones
        WHERE id_medidor = 5001
    """)
    medidor_5001_facts = cur_check.fetchone()[0]

    cur_check.close()
    conn_check.close()

    conn_lock.rollback()
    cur_lock.close()
    conn_lock.close()

    assert medidor_5002_facts == 1, "Unlocked medidor 5002 should have been processed"
    assert medidor_5001_facts == 0, "Locked medidor 5001 should have been skipped"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
