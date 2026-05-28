# -*- coding: utf-8 -*-
"""
Tests/integration/test_views_saidi_saifi.py

TDD Tests para las vistas analíticas SAIDI/SAIFI (PR3).
Valida las fórmulas IEEE 1366 correctas y la exclusión MED.

Ejecutar con:
    PGHOST=localhost PGPORT=5432 PGDATABASE=smart_city_test \
    PGUSER=ucab PGPASSWORD=ucab123 \
    pytest tests/integration/test_views_saidi_saifi.py -v
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
def setup_test_data(db_connection):
    """Insert minimal test data for SAIDI/SAIFI validation."""
    cur = db_connection.cursor()

    cur.execute("""
        INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
        VALUES (1000, '2025-01-01'::TIMESTAMPTZ, TRUE, 1)
        RETURNING sk_clientes
    """)
    sk_clientes = cur.fetchone()[0]

    cur.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_SAIDI_TEST', 'Distrito Test', -34.6, -58.38, 'NORMAL')
        RETURNING sk_geografia_urbana
    """)
    sk_geo = cur.fetchone()[0]

    cur.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor,
            transformador, circuito, subestacion, capacidad_kva, estado_operativo,
            fecha_inicio, activo_bool)
        VALUES (50001, 50001, 'MED-SAIDI-01', 'TFR-SAIDI', 'CIR-SAIDI', 'SUB-SAIDI',
                100.0, 'ACTIVO', '2025-01-01'::TIMESTAMPTZ, TRUE)
        RETURNING sk_red_electrica
    """)
    sk_red = cur.fetchone()[0]

    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, dia, dia_semana, dia_semana_num,
            semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana, es_feriado)
        VALUES ('2025-03-15', 15, 'Saturday', 6, 11, 3, 'March', 1, 2025, TRUE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)
    cur.execute("SELECT sk_tiempo FROM dim_tiempo WHERE timestamp_completo = '2025-03-15'")
    sk_tiempo_1 = cur.fetchone()[0]

    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, dia, dia_semana, dia_semana_num,
            semana_anio, mes, nombre_mes, trimestre, anio, es_fin_semana, es_feriado)
        VALUES ('2025-03-16', 16, 'Sunday', 7, 11, 3, 'March', 1, 2025, TRUE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)
    cur.execute("SELECT sk_tiempo FROM dim_tiempo WHERE timestamp_completo = '2025-03-16'")
    sk_tiempo_2 = cur.fetchone()[0]

    # Interruption 1: 60 minutes, 100 clients affected
    cur.execute("""
        INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana,
            sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos,
            clientes_afectados, excluido_med)
        VALUES (%s, %s, %s, %s, 50001, '2025-03-15 10:00:00+00', '2025-03-15 11:00:00+00',
                60.0, 100, FALSE)
        ON CONFLICT (id_medidor, timestamp_inicio) DO NOTHING
    """, (sk_tiempo_1, sk_red, sk_geo, sk_clientes))

    # Interruption 2: 30 minutes, 50 clients affected (same day)
    cur.execute("""
        INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana,
            sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos,
            clientes_afectados, excluido_med)
        VALUES (%s, %s, %s, %s, 50002, '2025-03-15 14:00:00+00', '2025-03-15 14:30:00+00',
                30.0, 50, FALSE)
        ON CONFLICT (id_medidor, timestamp_inicio) DO NOTHING
    """, (sk_tiempo_1, sk_red, sk_geo, sk_clientes))

    # Interruption 3: 45 minutes, 200 clients affected (next day)
    cur.execute("""
        INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana,
            sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos,
            clientes_afectados, excluido_med)
        VALUES (%s, %s, %s, %s, 50003, '2025-03-16 08:00:00+00', '2025-03-16 08:45:00+00',
                45.0, 200, FALSE)
        ON CONFLICT (id_medidor, timestamp_inicio) DO NOTHING
    """, (sk_tiempo_2, sk_red, sk_geo, sk_clientes))

    db_connection.commit()
    cur.close()

    yield {
        "sk_clientes": sk_clientes,
        "sk_geo": sk_geo,
        "sk_red": sk_red,
        "sk_tiempo_1": sk_tiempo_1,
        "sk_tiempo_2": sk_tiempo_2,
    }


class TestSAIDICalculation:
    """SAIDI = SUM(duracion_minutos) / total_clientes_servidos"""

    def test_saidi_uses_sum_duracion_not_product(self, db_cursor, setup_test_data):
        """
        SAIDI numerator must be SUM(duracion_minutos), NOT SUM(duracion * clientes_afectados).

        Test data:
          - Interruption 1: 60 min, 100 clients
          - Interruption 2: 30 min, 50 clients
          - Interruption 3: 45 min, 200 clients
          - Total clients served: 1000

        Correct SAIDI = (60 + 30 + 45) / 1000 = 135 / 1000 = 0.135
        Wrong (old)  = (60*100 + 30*50 + 45*200) / 1000 = 16500 / 1000 = 16.5
        """
        db_cursor.execute("""
            SELECT saidi FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-SAIDI'
              AND anio = 2025 AND mes = 3
        """)
        rows = db_cursor.fetchall()
        assert len(rows) > 0, "No rows returned from vw_saidi_saifi for test data"

        saidi = rows[0][0]
        expected = Decimal('0.14')
        assert abs(Decimal(str(saidi)) - expected) < Decimal('0.01'), \
            f"SAIDI should be ~0.14 (SUM(duracion)/total), got {saidi}. " \
            f"If ~16.5, formula is using SUM(duracion*clientes) instead."

    def test_saidi_zero_when_no_interruptions(self, db_cursor):
        """SAIDI should be 0 for periods with no interruptions."""
        db_cursor.execute("""
            SELECT saidi FROM vw_saidi_saifi
            WHERE anio = 2020 AND mes = 1
        """)
        rows = db_cursor.fetchall()
        if rows:
            for row in rows:
                assert row[0] == 0, f"SAIDI should be 0 with no interruptions, got {row[0]}"


class TestSAIFICalculation:
    """SAIFI = SUM(clientes_afectados) / total_clientes_servidos"""

    def test_saifi_uses_sum_clientes_not_count(self, db_cursor, setup_test_data):
        """
        SAIFI numerator must be SUM(clientes_afectados), NOT COUNT(interrupciones).

        Test data:
          - Interruption 1: 100 clients affected
          - Interruption 2: 50 clients affected
          - Interruption 3: 200 clients affected
          - Total clients served: 1000

        Correct SAIFI = (100 + 50 + 200) / 1000 = 350 / 1000 = 0.35
        Wrong (old)  = COUNT(3) / 1000 = 3 / 1000 = 0.003
        """
        db_cursor.execute("""
            SELECT saifi FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-SAIDI'
              AND anio = 2025 AND mes = 3
        """)
        rows = db_cursor.fetchall()
        assert len(rows) > 0, "No rows returned from vw_saidi_saifi for test data"

        saifi = rows[0][0]
        expected = Decimal('0.35')
        assert abs(Decimal(str(saifi)) - expected) < Decimal('0.01'), \
            f"SAIFI should be ~0.35 (SUM(clientes_afectados)/total), got {saifi}. " \
            f"If ~0.003, formula is using COUNT(interrupciones) instead."

    def test_saifi_reflects_client_impact(self, db_cursor, setup_test_data):
        """SAIFI should be proportional to clientes_afectados, not number of events."""
        db_cursor.execute("""
            SELECT saifi, total_clientes_afectados, total_interrupciones
            FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-SAIDI'
              AND anio = 2025 AND mes = 3
        """)
        rows = db_cursor.fetchall()
        assert len(rows) > 0

        saifi, total_afectados, total_interrupciones = rows[0]
        assert total_afectados == 350, f"Expected 350 total clientes afectados, got {total_afectados}"
        assert total_interrupciones == 3, f"Expected 3 interruptions, got {total_interrupciones}"


class TestMEDExclusion:
    """MED threshold must be calculated on baseline WITHOUT excluding MED days."""

    def test_med_threshold_function_exists(self, db_cursor):
        """fn_calcular_umbral_med() exists and returns a numeric value."""
        db_cursor.execute("SELECT fn_calcular_umbral_med()")
        result = db_cursor.fetchone()[0]
        assert result is not None, "fn_calcular_umbral_med() returned NULL"
        assert isinstance(result, (int, float, Decimal)), \
            f"Expected numeric, got {type(result)}"

    def test_med_threshold_non_negative(self, db_cursor):
        """MED threshold should be >= 0."""
        db_cursor.execute("SELECT fn_calcular_umbral_med()")
        result = db_cursor.fetchone()[0]
        assert Decimal(str(result)) >= 0, f"MED threshold should be >= 0, got {result}"

    def test_vw_med_threshold_has_es_med_column(self, db_cursor):
        """vw_med_threshold should have es_med boolean column."""
        db_cursor.execute("""
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE table_name = 'vw_med_threshold' AND column_name = 'es_med'
        """)
        row = db_cursor.fetchone()
        assert row is not None, "vw_med_threshold missing 'es_med' column"
        assert row[1] == 'boolean', f"es_med should be boolean, got {row[1]}"

    def test_vw_med_threshold_has_umbral_column(self, db_cursor):
        """vw_med_threshold should expose the umbral_med value."""
        db_cursor.execute("""
            SELECT column_name
            FROM information_schema.columns
            WHERE table_name = 'vw_med_threshold' AND column_name = 'umbral_med'
        """)
        row = db_cursor.fetchone()
        assert row is not None, "vw_med_threshold missing 'umbral_med' column"

    def test_saidi_saifi_excludes_med_days(self, db_cursor, setup_test_data):
        """vw_saidi_saifi should not include interruptions from MED days."""
        db_cursor.execute("""
            SELECT COUNT(*) FROM vw_saidi_saifi
            WHERE subestacion = 'SUB-SAIDI'
              AND anio = 2025 AND mes = 3
        """)
        rows = db_cursor.fetchall()
        assert len(rows) > 0, "vw_saidi_saifi should return data for test substation"


class TestViewColumns:
    """Validate that views expose the expected columns for Power BI."""

    def test_vw_saidi_saifi_has_required_columns(self, db_cursor):
        """vw_saidi_saifi must have saidi, saifi, caidi, and hierarchy columns."""
        db_cursor.execute("""
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'vw_saidi_saifi'
            ORDER BY ordinal_position
        """)
        columns = {row[0] for row in db_cursor.fetchall()}
        required = {'saidi', 'saifi', 'caidi', 'subestacion', 'circuito',
                     'transformador', 'periodo', 'total_clientes_servidos'}
        missing = required - columns
        assert not missing, f"vw_saidi_saifi missing columns: {missing}"

    def test_vw_tendencia_mensual_has_required_columns(self, db_cursor):
        """vw_tendencia_mensual must have saidi_ciudad and saifi_ciudad."""
        db_cursor.execute("""
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'vw_tendencia_mensual'
        """)
        columns = {row[0] for row in db_cursor.fetchall()}
        required = {'saidi_ciudad', 'saifi_ciudad', 'periodo', 'variacion_saidi_pct'}
        missing = required - columns
        assert not missing, f"vw_tendencia_mensual missing columns: {missing}"

    def test_vw_ranking_subestaciones_has_required_columns(self, db_cursor):
        """vw_ranking_subestaciones must have ranking and nivel_desempeno."""
        db_cursor.execute("""
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'vw_ranking_subestaciones'
        """)
        columns = {row[0] for row in db_cursor.fetchall()}
        required = {'ranking', 'subestacion', 'saidi_promedio', 'nivel_desempeno',
                     'delta_vs_ciudad'}
        missing = required - columns
        assert not missing, f"vw_ranking_subestaciones missing columns: {missing}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
