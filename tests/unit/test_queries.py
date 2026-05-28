"""Tests for dashboard/data/queries.py — singleton engine and fillna usage."""

import ast
import inspect
import textwrap
from unittest.mock import patch, MagicMock

import pytest


class TestSingletonEngine:
    """Module-level _engine must be reused across calls (no create_engine per call)."""

    def test_get_engine_returns_same_instance(self):
        from dashboard.data import queries

        queries._engine = None
        with patch.dict("os.environ", {"DATABASE_URL": "postgresql://u:p@localhost/test"}):
            e1 = queries.get_engine()
            e2 = queries.get_engine()
            assert e1 is e2

    def test_get_engine_has_pool_pre_ping(self):
        from dashboard.data import queries

        queries._engine = None
        with patch.dict("os.environ", {"DATABASE_URL": "postgresql://u:p@localhost/test"}):
            engine = queries.get_engine()
            assert engine.pool._pre_ping is True

    def test_get_engine_raises_without_database_url(self):
        from dashboard.data import queries

        queries._engine = None
        with patch.dict("os.environ", {}, clear=True):
            with pytest.raises(RuntimeError, match="DATABASE_URL"):
                queries.get_engine()

    def test_no_load_dotenv_in_module(self):
        from dashboard.data import queries

        source = inspect.getsource(queries)
        assert "load_dotenv" not in source


class TestFillnaUsage:
    """All pandas fill operations must use .fillna(), not .fill()."""

    def test_no_fill_method_in_queries_source(self):
        from dashboard.data import queries

        source = inspect.getsource(queries)
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and node.attr == "fill":
                pytest.fail("Found .fill() call in queries.py — must use .fillna()")

    def test_no_fill_method_in_callbacks_source(self):
        from dashboard import callbacks

        source = inspect.getsource(callbacks)
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and node.attr == "fill":
                pytest.fail("Found .fill() call in callbacks.py — must use .fillna()")

    def test_no_fill_method_in_charts_source(self):
        from dashboard.components import charts

        source = inspect.getsource(charts)
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and node.attr == "fill":
                pytest.fail("Found .fill() call in charts.py — must use .fillna()")


class TestDimensionQueries:
    """Dimension lookup functions must return DataFrames from DB."""

    def test_get_distinct_sectors_returns_dataframe(self, db_engine):
        from dashboard.data import queries

        queries._engine = db_engine
        df = queries.get_distinct_sectors()
        assert "sector_urbano" in df.columns

    def test_get_distinct_criticality_returns_dataframe(self, db_engine):
        from dashboard.data import queries

        queries._engine = db_engine
        df = queries.get_distinct_criticality()
        assert "nivel_criticidad" in df.columns

    def test_get_distinct_subestaciones_returns_dataframe(self, db_engine):
        from dashboard.data import queries

        queries._engine = db_engine
        df = queries.get_distinct_subestaciones()
        assert "subestacion" in df.columns
