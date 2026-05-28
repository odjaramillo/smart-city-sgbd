# -*- coding: utf-8 -*-
"""
Tests/integration/test_elt_cross_batch.py

TDD Tests para verificar el emparejamiento cross-batch: un OUTAGE en un lote
anterior se empareja correctamente con un RESTORATION en el lote siguiente,
calculando la duración correcta (ej: 90 minutos).

Ejecutar con:
    pytest tests/integration/test_elt_cross_batch.py -v

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
def setup_dimensions():
    """Insert dimension rows required by the SP."""
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, dia, dia_semana, dia_semana_num,
            semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana, es_feriado)
        VALUES ('2025-04-10', 10, 'Thursday', 4, 15, 4, 'April', 2, 2025, FALSE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_CROSS_TEST', 'Distrito Cross', -34.5, -58.4, 'NORMAL')
        ON CONFLICT (sector_urbano) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor,
            transformador, circuito, subestacion, fecha_inicio, activo_bool)
        VALUES (6001, 6001, 'MED-CROSS-6001', 'TFR-CROSS', 'CIR-CROSS', 'SUB-CROSS',
                '2024-01-01 00:00:00+00', TRUE)
        ON CONFLICT (id_medidor_origen, fecha_inicio) DO NOTHING
    """)

    cur.execute("""
        INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
        VALUES (1000, '2024-01-01 00:00:00+00', TRUE, 1)
    """)

    yield
    cur.close()
    conn.close()


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


def test_cross_batch_pairing_90_minutes(setup_dimensions, cleanup):
    """
    OUTAGE in batch A + RESTORATION in batch B must produce a fact
    with correct duration (90 minutes).

    Batch A: insert OUTAGE → run SP → OUTAGE stays unprocessed (open event)
    Batch B: insert RESTORATION → run SP → pairs with batch A's OUTAGE
    """
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    # --- Batch A: insert OUTAGE only ---
    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES (6001, '2025-04-10 10:00:00+00', 'POWER_OUTAGE')
    """)

    # Run SP for batch A
    cur.execute("CALL sp_reconciliar_interrupciones(NULL)")

    # Verify OUTAGE is still unprocessed (open event, no pair yet)
    cur.execute("""
        SELECT procesado FROM staging_eventos
        WHERE id_medidor = 6001 AND tipo_evento = 'POWER_OUTAGE'
    """)
    result = cur.fetchone()
    assert result is not None, "OUTAGE event should exist in staging"
    assert result[0] is False, "OUTAGE without RESTORATION should remain unprocessed"

    # Verify no fact was created yet
    cur.execute("SELECT COUNT(*) FROM fact_interrupciones WHERE id_medidor = 6001")
    assert cur.fetchone()[0] == 0, "No fact should exist without RESTORATION"

    # --- Batch B: insert RESTORATION (90 minutes after OUTAGE) ---
    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES (6001, '2025-04-10 11:30:00+00', 'POWER_RESTORATION')
    """)

    # Run SP for batch B — should pair with batch A's OUTAGE
    cur.execute("CALL sp_reconciliar_interrupciones(NULL)")

    # Verify fact was created with correct duration
    cur.execute("""
        SELECT duracion_minutos, timestamp_inicio, timestamp_fin
        FROM fact_interrupciones
        WHERE id_medidor = 6001
    """)
    fact = cur.fetchone()
    assert fact is not None, "Fact should exist after cross-batch pairing"

    duracion, ts_inicio, ts_fin = fact
    assert duracion == 90.0, f"Expected 90 minutes duration, got {duracion}"

    # Verify both staging events are now processed
    cur.execute("""
        SELECT COUNT(*) FROM staging_eventos
        WHERE id_medidor = 6001 AND procesado = TRUE
    """)
    assert cur.fetchone()[0] == 2, "Both events should be marked as processed"

    cur.close()
    conn.close()


def test_cross_batch_multiple_outages(setup_dimensions, cleanup):
    """
    Multiple OUTAGE→RESTORATION pairs across batches for the same medidor.
    """
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    # Batch A: first pair complete + one open OUTAGE
    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES
            (6001, '2025-04-10 08:00:00+00', 'POWER_OUTAGE'),
            (6001, '2025-04-10 08:30:00+00', 'POWER_RESTORATION'),
            (6001, '2025-04-10 14:00:00+00', 'POWER_OUTAGE')
    """)

    cur.execute("CALL sp_reconciliar_interrupciones(NULL)")

    # Verify first pair created a fact (30 min)
    cur.execute("""
        SELECT COUNT(*) FROM fact_interrupciones WHERE id_medidor = 6001
    """)
    assert cur.fetchone()[0] == 1, "First pair should create one fact"

    # Verify the open OUTAGE is still unprocessed
    cur.execute("""
        SELECT procesado FROM staging_eventos
        WHERE id_medidor = 6001 AND tipo_evento = 'POWER_OUTAGE'
          AND timestamp_evento = '2025-04-10 14:00:00+00'
    """)
    result = cur.fetchone()
    assert result[0] is False, "Open OUTAGE should remain unprocessed"

    # Batch B: RESTORATION arrives for the open OUTAGE
    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES (6001, '2025-04-10 15:00:00+00', 'POWER_RESTORATION')
    """)

    cur.execute("CALL sp_reconciliar_interrupciones(NULL)")

    # Verify second fact created (60 min)
    cur.execute("""
        SELECT duracion_minutos FROM fact_interrupciones
        WHERE id_medidor = 6001
        ORDER BY timestamp_inicio
    """)
    facts = cur.fetchall()
    assert len(facts) == 2, f"Expected 2 facts, got {len(facts)}"
    assert facts[0][0] == 30.0, f"First fact duration should be 30 min, got {facts[0][0]}"
    assert facts[1][0] == 60.0, f"Second fact duration should be 60 min, got {facts[1][0]}"

    cur.close()
    conn.close()


def test_idempotent_rerun_no_duplicate_facts(setup_dimensions, cleanup):
    """
    Running the SP twice on the same staging data must NOT create duplicate facts.
    """
    conn = _get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento)
        VALUES
            (6001, '2025-04-10 10:00:00+00', 'POWER_OUTAGE'),
            (6001, '2025-04-10 11:30:00+00', 'POWER_RESTORATION')
    """)

    # First run
    cur.execute("CALL sp_reconciliar_interrupciones(NULL)")

    cur.execute("SELECT COUNT(*) FROM fact_interrupciones WHERE id_medidor = 6001")
    first_count = cur.fetchone()[0]
    assert first_count == 1

    # Second run (all staging already processed, should be a no-op)
    cur.execute("CALL sp_reconciliar_interrupciones(NULL)")

    cur.execute("SELECT COUNT(*) FROM fact_interrupciones WHERE id_medidor = 6001")
    second_count = cur.fetchone()[0]
    assert second_count == 1, f"Idempotent rerun should not create duplicates, got {second_count} facts"

    cur.close()
    conn.close()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
