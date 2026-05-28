# -*- coding: utf-8 -*-
"""
Tests/integration/test_views_granularity.py

TDD Tests para validar granularidad correcta en vistas analíticas (PR3).
Verifica que no haya duplicados Cartesianos por GROUPING SETS y que
el drill-down jerárquico produzca agregaciones correctas.

Ejecutar con:
    PGHOST=localhost PGPORT=5432 PGDATABASE=smart_city_test \
    PGUSER=ucab PGPASSWORD=ucab123 \
    pytest tests/integration/test_views_granularity.py -v
"""

import os
import pytest
import psycopg2
from decimal import Decimal


@pytest.fixture(scope="session")
def db_connection():
    conn = psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "smart_city_test"),
        user=os.getenv("PGUSER", "ucab"),
        password=os.getenv("PGPASSWORD", "ucab123")
    )
    yield conn
    conn.close()


@pytest.fixture(scope="function")
def db_cursor(db_connection):
    cur = db_connection.cursor()
    yield cur
    db_connection.rollback()
    cur.close()


@pytest.fixture(scope="session")
def setup_granularity_data(db_connection):
    """
    Insert test data with multiple substations, circuits, and transformers
    to validate hierarchical drill-down aggregation.

    Topology:
      SUB-GRAN-A
        ├── CIR-A1
        │   ├── TFR-A1-01 (medidor 60001)
        │   └── TFR-A1-02 (medidor 60002)
        └── CIR-A2
            └── TFR-A2-01 (medidor 60003)
      SUB-GRAN-B
        └── CIR-B1
            └── TFR-B1-01 (medidor 60004)
    """
    cur = db_connection.cursor()

    cur.execute("DELETE FROM fact_interrupciones")
    cur.execute("DELETE FROM dim_clientes_inventario")

    cur.execute("""
        INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
        VALUES (500, '2025-01-01'::TIMESTAMPTZ, TRUE, 1)
        RETURNING sk_clientes
    """)
    sk_clientes = cur.fetchone()[0]

    cur.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_GRAN_TEST', 'Distrito Gran', -34.6, -58.38, 'NORMAL')
        ON CONFLICT (sector_urbano) DO NOTHING
        RETURNING sk_geografia_urbana
    """)
    result = cur.fetchone()
    if result:
        sk_geo = result[0]
    else:
        cur.execute("""
            SELECT sk_geografia_urbana FROM dim_geografia_urbana
            WHERE sector_urbano = 'SECTOR_GRAN_TEST'
        """)
        sk_geo = cur.fetchone()[0]

    medidores = [
        (60001, 60001, 'MED-GRAN-01', 'TFR-A1-01', 'CIR-A1', 'SUB-GRAN-A'),
        (60002, 60002, 'MED-GRAN-02', 'TFR-A1-02', 'CIR-A1', 'SUB-GRAN-A'),
        (60003, 60003, 'MED-GRAN-03', 'TFR-A2-01', 'CIR-A2', 'SUB-GRAN-A'),
        (60004, 60004, 'MED-GRAN-04', 'TFR-B1-01', 'CIR-B1', 'SUB-GRAN-B'),
    ]
    sk_reds = []
    for med in medidores:
        cur.execute("""
            INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor,
                transformador, circuito, subestacion, capacidad_kva, estado_operativo,
                fecha_inicio, activo_bool)
            VALUES (%s, %s, %s, %s, %s, %s, 100.0, 'ACTIVO', '2025-01-01'::TIMESTAMPTZ, TRUE)
            ON CONFLICT (id_medidor_origen, fecha_inicio) DO NOTHING
            RETURNING sk_red_electrica
        """, med)
        result = cur.fetchone()
        if result:
            sk_reds.append(result[0])
        else:
            cur.execute("""
                SELECT sk_red_electrica FROM dim_red_electrica
                WHERE id_medidor_origen = %s AND activo_bool = TRUE
                LIMIT 1
            """, (med[1],))
            sk_reds.append(cur.fetchone()[0])

    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, dia, dia_semana, dia_semana_num,
            semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana, es_feriado)
        VALUES ('2025-04-10', 10, 'Thursday', 4, 15, 4, 'April', 2, 2025, FALSE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)
    cur.execute("SELECT sk_tiempo FROM dim_tiempo WHERE timestamp_completo = '2025-04-10'")
    sk_tiempo = cur.fetchone()[0]

    interrupciones = [
        (sk_tiempo, sk_reds[0], sk_geo, sk_clientes, 60001,
         '2025-04-10 09:00:00+00', '2025-04-10 09:30:00+00', 30.0, 20),
        (sk_tiempo, sk_reds[1], sk_geo, sk_clientes, 60002,
         '2025-04-10 10:00:00+00', '2025-04-10 10:45:00+00', 45.0, 30),
        (sk_tiempo, sk_reds[2], sk_geo, sk_clientes, 60003,
         '2025-04-10 11:00:00+00', '2025-04-10 11:20:00+00', 20.0, 10),
        (sk_tiempo, sk_reds[3], sk_geo, sk_clientes, 60004,
         '2025-04-10 14:00:00+00', '2025-04-10 14:50:00+00', 50.0, 40),
    ]
    for intr in interrupciones:
        cur.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana,
                sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos,
                clientes_afectados, excluido_med)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, FALSE)
            ON CONFLICT (id_medidor, timestamp_inicio) DO NOTHING
        """, intr)

    db_connection.commit()
    cur.close()

    yield {
        "sk_clientes": sk_clientes,
        "sk_geo": sk_geo,
        "sk_reds": sk_reds,
        "sk_tiempo": sk_tiempo,
    }


class TestNoCartesianDuplicates:
    """Queries at substation level should not produce Cartesian duplicates."""

    def test_no_duplicate_rows_per_transformer_month(self, db_cursor, setup_granularity_data):
        """
        Each (subestacion, circuito, transformador, anio, mes) combination
        should appear exactly once in vw_saidi_saifi.
        Multiple rows per transformer would indicate GROUPING SETS contamination.
        """
        db_cursor.execute("""
            SELECT subestacion, circuito, transformador, anio, mes, COUNT(*) AS row_count
            FROM vw_saidi_saifi
            WHERE subestacion IN ('SUB-GRAN-A', 'SUB-GRAN-B')
              AND anio = 2025 AND mes = 4
            GROUP BY subestacion, circuito, transformador, anio, mes
        """)
        rows = db_cursor.fetchall()
        assert len(rows) > 0, "No data found for test substations"

        for row in rows:
            sub, cir, tfr, anio, mes, count = row
            assert count == 1, \
                f"{sub}/{cir}/{tfr} has {count} rows for {anio}-{mes}, expected 1. " \
                f"Possible GROUPING SETS subtotal contamination."

    def test_substation_level_aggregation_correct(self, db_cursor, setup_granularity_data):
        """
        SUB-GRAN-A should aggregate all 3 interruptions (medidores 60001, 60002, 60003).
        Total duracion = 30 + 45 + 20 = 95 min.
        Total clientes_afectados = 20 + 30 + 10 = 60.
        """
        db_cursor.execute("""
            SELECT suma_duracion_minutos, total_clientes_afectados, total_interrupciones
            FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-GRAN-A'
              AND anio = 2025 AND mes = 4
              AND circuito IS NOT NULL AND transformador IS NOT NULL
        """)
        rows = db_cursor.fetchall()

        total_duracion = sum(r[0] for r in rows)
        total_afectados = sum(r[1] for r in rows)
        total_interrupciones = sum(r[2] for r in rows)

        assert total_duracion == 95, \
            f"SUB-GRAN-A total duracion should be 95, got {total_duracion}"
        assert total_afectados == 60, \
            f"SUB-GRAN-A total clientes_afectados should be 60, got {total_afectados}"
        assert total_interrupciones == 3, \
            f"SUB-GRAN-A should have 3 interruptions, got {total_interrupciones}"


class TestHierarchicalDrillDown:
    """Validate drill-down: Ciudad → Subestación → Circuito → Transformador."""

    def test_transformer_level_granularity(self, db_cursor, setup_granularity_data):
        """
        Each transformer should have its own row with correct individual metrics.
        TFR-A1-01: 30 min, 20 clients
        TFR-A1-02: 45 min, 30 clients
        """
        db_cursor.execute("""
            SELECT transformador, suma_duracion_minutos, total_clientes_afectados
            FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-GRAN-A'
              AND circuito = 'CIR-A1'
              AND anio = 2025 AND mes = 4
            ORDER BY transformador
        """)
        rows = db_cursor.fetchall()
        assert len(rows) == 2, f"Expected 2 transformers in CIR-A1, got {len(rows)}"

        transformers = {r[0]: (r[1], r[2]) for r in rows}
        assert transformers.get('TFR-A1-01') == (Decimal('30.0') if isinstance(transformers.get('TFR-A1-01', (0,0))[0], Decimal) else 30.0, 20), \
            f"TFR-A1-01 should have 30 min / 20 clients, got {transformers.get('TFR-A1-01')}"
        assert transformers.get('TFR-A1-02') == (Decimal('45.0') if isinstance(transformers.get('TFR-A1-02', (0,0))[0], Decimal) else 45.0, 30), \
            f"TFR-A1-02 should have 45 min / 30 clients, got {transformers.get('TFR-A1-02')}"

    def test_circuit_level_aggregation(self, db_cursor, setup_granularity_data):
        """
        CIR-A1 should aggregate TFR-A1-01 + TFR-A1-02:
          duracion = 30 + 45 = 75, clientes_afectados = 20 + 30 = 50
        CIR-A2 has only TFR-A2-01:
          duracion = 20, clientes_afectados = 10
        """
        db_cursor.execute("""
            SELECT circuito,
                   SUM(suma_duracion_minutos) AS total_duracion,
                   SUM(total_clientes_afectados) AS total_afectados
            FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-GRAN-A'
              AND anio = 2025 AND mes = 4
            GROUP BY circuito
            ORDER BY circuito
        """)
        rows = db_cursor.fetchall()
        circuits = {r[0]: (r[1], r[2]) for r in rows}

        assert 'CIR-A1' in circuits, "CIR-A1 not found in results"
        assert circuits['CIR-A1'][0] == 75, \
            f"CIR-A1 total duracion should be 75, got {circuits['CIR-A1'][0]}"
        assert circuits['CIR-A1'][1] == 50, \
            f"CIR-A1 total clientes_afectados should be 50, got {circuits['CIR-A1'][1]}"

        assert 'CIR-A2' in circuits, "CIR-A2 not found in results"
        assert circuits['CIR-A2'][0] == 20, \
            f"CIR-A2 total duracion should be 20, got {circuits['CIR-A2'][0]}"

    def test_substation_b_isolation(self, db_cursor, setup_granularity_data):
        """
        SUB-GRAN-B should have only its own interruption:
          duracion = 50, clientes_afectados = 40
        Must NOT include SUB-GRAN-A data (no cross-contamination).
        """
        db_cursor.execute("""
            SELECT SUM(suma_duracion_minutos), SUM(total_clientes_afectados),
                   SUM(total_interrupciones)
            FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-GRAN-B'
              AND anio = 2025 AND mes = 4
        """)
        row = db_cursor.fetchone()
        assert row[0] == 50, f"SUB-GRAN-B duracion should be 50, got {row[0]}"
        assert row[1] == 40, f"SUB-GRAN-B clientes_afectados should be 40, got {row[1]}"
        assert row[2] == 1, f"SUB-GRAN-B should have 1 interruption, got {row[2]}"


class TestGroupByGranularity:
    """GROUP BY at correct granularity prevents aggregation over GROUPING SETS subtotals."""

    def test_no_null_subestacion_in_saidi_saifi(self, db_cursor, setup_granularity_data):
        """
        vw_saidi_saifi should NOT have rows with NULL subestacion.
        NULL subestacion would indicate GROUPING SETS subtotals leaking into
        the detail view. City-level totals belong in vw_tendencia_mensual.
        """
        db_cursor.execute("""
            SELECT COUNT(*) FROM vw_saidi_saifi
            WHERE subestacion IS NULL
        """)
        count = db_cursor.fetchone()[0]
        assert count == 0, \
            f"vw_saidi_saifi has {count} rows with NULL subestacion. " \
            f"GROUPING SETS subtotals should not appear in this view."

    def test_no_null_circuito_in_saidi_saifi(self, db_cursor, setup_granularity_data):
        """
        vw_saidi_saifi should NOT have rows with NULL circuito.
        Each row must be at the transformer granularity level.
        """
        db_cursor.execute("""
            SELECT COUNT(*) FROM vw_saidi_saifi
            WHERE circuito IS NULL AND subestacion IS NOT NULL
        """)
        count = db_cursor.fetchone()[0]
        assert count == 0, \
            f"vw_saidi_saifi has {count} rows with NULL circuito but non-NULL subestacion. " \
            f"Partial aggregation rows should not exist."

    def test_tendencia_mensual_is_city_level(self, db_cursor):
        """
        vw_tendencia_mensual should be city-level (no subestacion column).
        This separates concerns: detail in vw_saidi_saifi, totals here.
        """
        db_cursor.execute("""
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'vw_tendencia_mensual' AND column_name = 'subestacion'
        """)
        row = db_cursor.fetchone()
        assert row is None, \
            "vw_tendencia_mensual should NOT have 'subestacion' column. " \
            "City-level view should not mix with substation detail."

    def test_saidi_saifi_row_count_matches_topology(self, db_cursor, setup_granularity_data):
        """
        Row count for a given month should equal the number of distinct
        (subestacion, circuito, transformador) tuples with interruptions.
        Not more (no subtotals), not less (no data loss).
        """
        db_cursor.execute("""
            SELECT COUNT(*) FROM vw_saidi_saifi
            WHERE anio = 2025 AND mes = 4
              AND subestacion IN ('SUB-GRAN-A', 'SUB-GRAN-B')
        """)
        view_count = db_cursor.fetchone()[0]

        db_cursor.execute("""
            SELECT COUNT(DISTINCT (dre.subestacion, dre.circuito, dre.transformador))
            FROM fact_interrupciones fi
            JOIN dim_tiempo dt ON fi.sk_tiempo = dt.sk_tiempo
            JOIN dim_red_electrica dre ON fi.sk_red_electrica = dre.sk_red_electrica
            WHERE dt.anio = 2025 AND dt.mes = 4
              AND dre.subestacion IN ('SUB-GRAN-A', 'SUB-GRAN-B')
              AND fi.excluido_med = FALSE
        """)
        expected_count = db_cursor.fetchone()[0]

        assert view_count == expected_count, \
            f"vw_saidi_saifi has {view_count} rows but expected {expected_count} " \
            f"(one per distinct transformer with interruptions). " \
            f"Mismatch suggests GROUPING SETS contamination or data loss."


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
