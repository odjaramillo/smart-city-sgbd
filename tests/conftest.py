"""Shared pytest fixtures for smart-city-sgbd tests."""

import pytest


@pytest.fixture(scope="session")
def test_data():
    """Fixture for test data that can be reused across tests."""
    # Placeholder — will be populated as we add tests
    return {}
