# -*- coding: utf-8 -*-
"""
Tests/integration/test_ddl_constraints.py

TDD Tests para constraints del DDL v2 (rediseño-completo).
 Estas pruebas validan la integridad de datos a nivel de esquema.

Ejecutar con:
    pytest tests/integration/test_ddl_constraints.py -v

Requiere:
    - PostgreSQL corriendo con las tablas del DDL creadas
    - Variables de entorno: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
      (o defaults: localhost, 5432, smart_city_test, postgres, postgres)
"""

import os
import pytest
import psycopg2
from psycopg2 import sql


# ==============================================================================
# FIXTURES
# ==============================================================================

@pytest.fixture(scope="session")
def db_connection():
    """Connect to test database."""
    conn = psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "smart_city_test"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD", "postgres")
    )
    yield conn
    conn.close()


@pytest.fixture(scope="function")
def db_cursor(db_connection):
    """Create a cursor for each test, rolled back after."""
    cur = db_connection.cursor()
    yield cur
    db_connection.rollback()
    cur.close()


@pytest.fixture(scope="session")
def sample_geografia(db_connection):
    """Insert a sample geography row and return its sk."""
    cur = db_connection.cursor()
    cur.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_TEST_GEO', 'Distrito Test', -34.6, -58.38, 'NORMAL')
        RETURNING sk_geografia_urbana
    """)
    sk = cur.fetchone()[0]
    db_connection.commit()
    yield sk
    # Cleanup
    cur.execute("DELETE FROM dim_geografia_urbana WHERE sk_geografia_urbana = %s", (sk,))
    db_connection.commit()
    cur.close()


@pytest.fixture(scope="session")
def sample_red_electrica(db_connection):
    """Insert a sample red electrica row and return its sk."""
    cur = db_connection.cursor()
    cur.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor, transformador, circuito, subestacion, capacidad_kva, estado_operativo, fecha_inicio, activo_bool)
        VALUES (9999, 9999, 'MED-TEST-9999', 'Transformador Test', 'Circuito Test', 'Subestacion Test', 100.0, 'ACTIVO', NOW(), TRUE)
        RETURNING sk_red_electrica
    """)
    sk = cur.fetchone()[0]
    db_connection.commit()
    yield sk
    # Cleanup
    cur.execute("DELETE FROM dim_red_electrica WHERE sk_red_electrica = %s", (sk,))
    db_connection.commit()
    cur.close()


@pytest.fixture(scope="session")
def sample_clientes(db_connection):
    """Insert a sample clientes row and return its sk."""
    cur = db_connection.cursor()
    cur.execute("""
        INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
        VALUES (500, NOW(), TRUE, 1)
        RETURNING sk_clientes
    """)
    sk = cur.fetchone()[0]
    db_connection.commit()
    yield sk
    # Cleanup
    cur.execute("DELETE FROM dim_clientes_inventario WHERE sk_clientes = %s", (sk,))
    db_connection.commit()
    cur.close()


@pytest.fixture(scope="session")
def sample_tiempo(db_connection):
    """Insert a sample dim_tiempo row for testing."""
    cur = db_connection.cursor()
    cur.execute("""
        INSERT INTO dim_tiempo (timestamp_completo, anio, trimestre, mes, dia, dia_semana, dia_semana_num, semana_anio, nombre_mes, es_fin_semana, es_feriado)
        VALUES ('2025-01-15', 2025, 1, 1, 15, 'Miércoles', 3, 3, 'Enero', FALSE, FALSE)
        ON CONFLICT (timestamp_completo) DO NOTHING
    """)
    db_connection.commit()

    cur.execute("""
        SELECT sk_tiempo FROM dim_tiempo WHERE timestamp_completo = '2025-01-15'
    """)
    result = cur.fetchone()
    if result:
        yield result[0]
    else:
        pytest.skip("Could not create sample dim_tiempo row")


# ==============================================================================
# TEST: UNIQUE constraint on dim_geografia_urbana(sector_urbano)
# ==============================================================================

def test_unique_sector_urbano(db_cursor, db_connection):
    """
    UNIQUE constraint prevents duplicate sector_urbano.

    RED: Esta prueba falla si no existe la constraint UNIQUE.
    GREEN: El DDL v2 agrega UNIQUE(sector_urbano) a dim_geografia_urbana.
    """
    # Insert first row
    db_cursor.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_UNICO_TEST', 'Distrito Unico', -34.7, -58.4, 'MEDIO')
        RETURNING sk_geografia_urbana
    """)
    db_connection.commit()

    # Attempt duplicate should fail with IntegrityError
    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
            VALUES ('SECTOR_UNICO_TEST', 'Distrito Otro', -34.8, -58.5, 'ALTO')
        """)
        db_connection.commit()

    # Verify it's a uniqueness violation
    assert "uq_" in str(exc_info.value) or "unique" in str(exc_info.value).lower() or "duplicate" in str(exc_info.value).lower()


def test_unique_sector_urbano_allows_different_sectors(db_cursor, db_connection):
    """Different sector_urbano values should insert successfully."""
    db_cursor.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_A_DIFF', 'Distrito A', -34.1, -58.1, 'BAJO')
    """)
    db_cursor.execute("""
        INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
        VALUES ('SECTOR_B_DIFF', 'Distrito B', -34.2, -58.2, 'ALTO')
    """)
    db_connection.commit()
    # If we get here, both inserts succeeded


# ==============================================================================
# TEST: UNIQUE constraint on dim_red_electrica(id_medidor_origen, fecha_inicio)
# ==============================================================================

def test_unique_medidor_scd2(db_cursor, db_connection):
    """
    UNIQUE constraint (id_medidor_origen, fecha_inicio) prevents duplicate SCD2 records.

    RED: Esta prueba falla si no existe la constraint uq_medidor_scd2.
    GREEN: El DDL v2 agrega CONSTRAINT uq_medidor_scd2 UNIQUE (id_medidor_origen, fecha_inicio).
    """
    test_medidor_origen = 8888
    test_fecha_inicio = '2025-01-01 00:00:00+00'

    # Insert first SCD2 record
    db_cursor.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor, transformador, circuito, subestacion, capacidad_kva, estado_operativo, fecha_inicio, activo_bool)
        VALUES (8888, 8888, 'MED-8888', 'TFR-8888', 'CIR-8888', 'SUB-8888', 150.0, 'ACTIVO', %s, TRUE)
    """, (test_fecha_inicio,))
    db_connection.commit()

    # Attempt duplicate (same id_medidor_origen, same fecha_inicio) should fail
    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor, transformador, circuito, subestacion, capacidad_kva, estado_operativo, fecha_inicio, activo_bool)
            VALUES (8889, 8888, 'MED-8888-B', 'TFR-8888-B', 'CIR-8888', 'SUB-8888', 200.0, 'ACTIVO', %s, TRUE)
        """, (test_fecha_inicio,))
        db_connection.commit()

    assert "uq_medidor_scd2" in str(exc_info.value) or "unique" in str(exc_info.value).lower() or "duplicate" in str(exc_info.value).lower()


def test_scd2_allows_different_fecha_inicio(db_cursor, db_connection):
    """Same id_medidor_origen but different fecha_inicio should succeed (SCD2 history)."""
    test_medidor_origen = 8777

    # First record
    db_cursor.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor, transformador, circuito, subestacion, capacidad_kva, estado_operativo, fecha_inicio, activo_bool)
        VALUES (8777, 8777, 'MED-8777', 'TFR-8777', 'CIR-8777', 'SUB-8777', 100.0, 'ACTIVO', '2025-01-01 00:00:00+00', TRUE)
    """)
    db_connection.commit()

    # Second record with same id_medidor_origen but different fecha_inicio (SCD2 versioning)
    db_cursor.execute("""
        INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor, transformador, circuito, subestacion, capacidad_kva, estado_operativo, fecha_inicio, activo_bool)
        VALUES (8777, 8777, 'MED-8777', 'TFR-8777-NEW', 'CIR-8777', 'SUB-8777', 200.0, 'ACTIVO', '2025-06-01 00:00:00+00', TRUE)
    """)
    db_connection.commit()
    # If we get here, both inserts succeeded (SCD2 history preserved)


# ==============================================================================
# TEST: CHECK constraint on dim_clientes_inventario(total_clientes_servidos > 0)
# ==============================================================================

def test_check_clientes_positivo(db_cursor, db_connection):
    """
    CHECK constraint ensures total_clientes_servidos > 0.

    RED: Esta prueba falla si no existe el CHECK.
    GREEN: El DDL v2 agrega CHECK (total_clientes_servidos > 0).
    """
    # Attempt insert with 0 clientes should fail
    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
            VALUES (0, NOW(), TRUE, 1)
        """)
        db_connection.commit()

    assert "check" in str(exc_info.value).lower() or "violates" in str(exc_info.value).lower()


def test_check_clientes_negativo(db_cursor, db_connection):
    """CHECK constraint should reject negative values."""
    with pytest.raises(psycopg2.IntegrityError):
        db_cursor.execute("""
            INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
            VALUES (-100, NOW(), TRUE, 1)
        """)
        db_connection.commit()


def test_check_clientes_valido(db_cursor, db_connection):
    """CHECK constraint should allow positive values."""
    db_cursor.execute("""
        INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, activo_bool, version)
        VALUES (1000, NOW(), TRUE, 1)
    """)
    db_connection.commit()
    # If we get here, the insert succeeded


# ==============================================================================
# TEST: UNIQUE constraint on fact_interrupciones(id_medidor, timestamp_inicio)
# ==============================================================================

def test_unique_fact_medidor_timestamp(db_cursor, db_connection, sample_tiempo, sample_geografia, sample_red_electrica, sample_clientes):
    """
    UNIQUE constraint (id_medidor, timestamp_inicio) prevents duplicate facts.

    RED: Esta prueba falla si no existe uq_fact_medidor_inicio.
    GREEN: El DDL v2 agrega CONSTRAINT uq_fact_medidor_inicio UNIQUE (id_medidor, timestamp_inicio).
    """
    test_timestamp = '2025-01-15 10:00:00+00'
    test_medidor = 7777

    # Insert first fact
    db_cursor.execute("""
        INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
        VALUES (%s, %s, %s, %s, %s, %s, %s, 30.0, 50, 1, FALSE)
    """, (sample_tiempo, sample_red_electrica, sample_geografia, sample_clientes, test_medidor, test_timestamp, '2025-01-15 10:30:00+00'))
    db_connection.commit()

    # Attempt duplicate (same id_medidor, same timestamp_inicio) should fail
    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
            VALUES (%s, %s, %s, %s, %s, %s, %s, 45.0, 75, 1, FALSE)
        """, (sample_tiempo, sample_red_electrica, sample_geografia, sample_clientes, test_medidor, test_timestamp, '2025-01-15 10:45:00+00'))
        db_connection.commit()

    assert "uq_fact_medidor_inicio" in str(exc_info.value) or "unique" in str(exc_info.value).lower() or "duplicate" in str(exc_info.value).lower()


def test_fact_allows_different_medidor(db_cursor, db_connection, sample_tiempo, sample_geografia, sample_red_electrica, sample_clientes):
    """Same timestamp_inicio but different id_medidor should succeed."""
    test_timestamp = '2025-01-15 11:00:00+00'

    db_cursor.execute("""
        INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
        VALUES (%s, %s, %s, %s, 7001, %s, %s, 30.0, 50, 1, FALSE)
    """, (sample_tiempo, sample_red_electrica, sample_geografia, sample_clientes, test_timestamp, '2025-01-15 11:30:00+00'))

    db_cursor.execute("""
        INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
        VALUES (%s, %s, %s, %s, 7002, %s, %s, 30.0, 50, 1, FALSE)
    """, (sample_tiempo, sample_red_electrica, sample_geografia, sample_clientes, test_timestamp, '2025-01-15 11:30:00+00'))
    db_connection.commit()
    # If we get here, both inserts succeeded


# ==============================================================================
# TEST: Foreign Key integrity
# ==============================================================================

def test_fk_fact_tiempo_invalid(db_cursor, db_connection, sample_geografia, sample_red_electrica, sample_clientes):
    """
    FK constraint on fact_interrupciones.sk_tiempo should reject invalid sk_tiempo.
    """
    invalid_sk_tiempo = 999999  # Non-existent

    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
            VALUES (%s, %s, %s, %s, 6001, '2025-01-20 10:00:00+00', '2025-01-20 10:30:00+00', 30.0, 50, 1, FALSE)
        """, (invalid_sk_tiempo, sample_red_electrica, sample_geografia, sample_clientes))
        db_connection.commit()

    assert "fk_fact_tiempo" in str(exc_info.value) or "foreign key" in str(exc_info.value).lower() or "violates" in str(exc_info.value).lower()


def test_fk_fact_red_electrica_invalid(db_cursor, db_connection, sample_tiempo, sample_geografia, sample_clientes):
    """FK constraint on fact_interrupciones.sk_red_electrica should reject invalid sk."""
    invalid_sk_red = 999998  # Non-existent

    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
            VALUES (%s, %s, %s, %s, 6002, '2025-01-20 11:00:00+00', '2025-01-20 11:30:00+00', 30.0, 50, 1, FALSE)
        """, (sample_tiempo, invalid_sk_red, sample_geografia, sample_clientes))
        db_connection.commit()

    assert "fk_fact_red_electrica" in str(exc_info.value) or "foreign key" in str(exc_info.value).lower()


def test_fk_fact_geografia_invalid(db_cursor, db_connection, sample_tiempo, sample_red_electrica, sample_clientes):
    """FK constraint on fact_interrupciones.sk_geografia_urbana should reject invalid sk."""
    invalid_sk_geo = 999997  # Non-existent

    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
            VALUES (%s, %s, %s, %s, 6003, '2025-01-20 12:00:00+00', '2025-01-20 12:30:00+00', 30.0, 50, 1, FALSE)
        """, (sample_tiempo, sample_red_electrica, invalid_sk_geo, sample_clientes))
        db_connection.commit()

    assert "fk_fact_geografia" in str(exc_info.value) or "foreign key" in str(exc_info.value).lower()


def test_fk_fact_clientes_invalid(db_cursor, db_connection, sample_tiempo, sample_geografia, sample_red_electrica):
    """FK constraint on fact_interrupciones.sk_clientes should reject invalid sk."""
    invalid_sk_clientes = 999996  # Non-existent

    with pytest.raises(psycopg2.IntegrityError) as exc_info:
        db_cursor.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
            VALUES (%s, %s, %s, %s, 6004, '2025-01-20 13:00:00+00', '2025-01-20 13:30:00+00', 30.0, 50, 1, FALSE)
        """, (sample_tiempo, sample_red_electrica, sample_geografia, invalid_sk_clientes))
        db_connection.commit()

    assert "fk_fact_clientes" in str(exc_info.value) or "foreign key" in str(exc_info.value).lower()


# ==============================================================================
# TEST: CHECK constraints on fact_interrupciones
# ==============================================================================

def test_check_clientes_afectados_positivo(db_cursor, db_connection, sample_tiempo, sample_geografia, sample_red_electrica, sample_clientes):
    """CHECK constraint ensures clientes_afectados >= 1."""
    with pytest.raises(psycopg2.IntegrityError):
        db_cursor.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
            VALUES (%s, %s, %s, %s, 6005, '2025-01-20 14:00:00+00', '2025-01-20 14:30:00+00', 30.0, 0, 1, FALSE)
        """, (sample_tiempo, sample_red_electrica, sample_geografia, sample_clientes))
        db_connection.commit()


def test_check_fechas_interrupcion(db_cursor, db_connection, sample_tiempo, sample_geografia, sample_red_electrica, sample_clientes):
    """CHECK constraint ensures timestamp_fin > timestamp_inicio."""
    with pytest.raises(psycopg2.IntegrityError):
        db_cursor.execute("""
            INSERT INTO fact_interrupciones (sk_tiempo, sk_red_electrica, sk_geografia_urbana, sk_clientes, id_medidor, timestamp_inicio, timestamp_fin, duracion_minutos, clientes_afectados, id_lote_procesamiento, excluido_med)
            VALUES (%s, %s, %s, %s, 6006, '2025-01-20 15:00:00+00', '2025-01-20 14:00:00+00', -60.0, 50, 1, FALSE)
        """, (sample_tiempo, sample_red_electrica, sample_geografia, sample_clientes))
        db_connection.commit()


# ==============================================================================
# TEST: CHECK constraint on dim_geografia_urbana.nivel_criticidad
# ==============================================================================

def test_check_nivel_criticidad_invalido(db_cursor, db_connection):
    """CHECK constraint rejects invalid nivel_criticidad values in dim_geografia_urbana."""
    cur = db_cursor

    # Rollback any pending transaction first
    db_connection.rollback()

    # Attempt insert with invalid value should fail
    with pytest.raises(psycopg2.IntegrityError):
        cur.execute("""
            INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
            VALUES ('SECTOR_INVALIDO_TEST', 'Distrito Inv', -34.5, -58.3, 'INVALIDO')
        """)
        db_connection.commit()

    # Rollback to clean up
    db_connection.rollback()


# ==============================================================================
# TEST: Row count validation for dim_tiempo (day-level)
# ==============================================================================

def test_dim_tiempo_row_count(db_cursor):
    """
    Verify dim_tiempo has ~3,650 rows (day-level 2020-2029).

    Expected: 2020-01-01 to 2029-12-31 = 10 years ≈ 3,650 days
    """
    db_cursor.execute("SELECT COUNT(*) FROM dim_tiempo")
    count = db_cursor.fetchone()[0]

    # Should be approximately 3,650 (allowing for leap years and exact range)
    assert 3600 <= count <= 3660, f"dim_tiempo has {count} rows, expected ~3,650 (day-level)"


def test_dim_tiempo_is_date_not_timestamp(db_cursor):
    """Verify timestamp_completo is DATE type, not TIMESTAMPTZ."""
    db_cursor.execute("""
        SELECT data_type FROM information_schema.columns
        WHERE table_name = 'dim_tiempo' AND column_name = 'timestamp_completo'
    """)
    data_type = db_cursor.fetchone()[0]

    # PostgreSQL reports date as 'date'
    assert data_type == 'date', f"timestamp_completo has type {data_type}, expected 'date'"


# ==============================================================================
# TEST: Indexes exist for FK performance
# ==============================================================================

def test_fk_indexes_exist(db_cursor):
    """B-tree indexes exist on all FK columns for JOIN performance."""
    cur = db_cursor
    cur.execute("""
        SELECT indexname
        FROM pg_indexes
        WHERE tablename = 'fact_interrupciones'
        AND indexname LIKE 'idx_%'
    """)
    indexes = [row[0] for row in cur.fetchall()]

    # Check that FK indexes exist (matching actual DDL naming: idx_fact_sk_<column>)
    expected_indexes = [
        'idx_fact_sk_tiempo',
        'idx_fact_sk_geografia_urbana',
        'idx_fact_sk_red_electrica',
        'idx_fact_sk_clientes'
    ]
    for idx in expected_indexes:
        assert idx in indexes, f"Missing index: {idx}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
