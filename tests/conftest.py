"""Shared pytest fixtures for smart-city-sgbd tests."""

import os

import pytest
from sqlalchemy import create_engine


@pytest.fixture(scope="session")
def db_engine():
    """Module-level SQLAlchemy engine for test database (singleton)."""
    database_url = os.getenv(
        "DATABASE_URL",
        "postgresql://ucab:ucab123@localhost:5432/smart_city_test",
    )
    engine = create_engine(database_url, pool_pre_ping=True)
    yield engine
    engine.dispose()


@pytest.fixture(scope="session")
def test_data():
    """Fixture for test data that can be reused across tests."""
    return {}
