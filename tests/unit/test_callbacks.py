"""Tests for dashboard/callbacks.py — logging and error state propagation."""

import ast
import inspect
import logging
from unittest.mock import patch, MagicMock

import pytest


class TestExceptionLogging:
    """All except blocks in callbacks must use logging.exception()."""

    def test_no_bare_except_exception(self):
        from dashboard import callbacks

        source = inspect.getsource(callbacks)
        tree = ast.parse(source)

        for node in ast.walk(tree):
            if isinstance(node, ast.ExceptHandler):
                if node.type is None:
                    continue
                if isinstance(node.type, ast.Name) and node.type.id == "Exception":
                    has_logging = False
                    for child in ast.walk(node):
                        if isinstance(child, ast.Call):
                            func = child.func
                            if isinstance(func, ast.Attribute) and func.attr == "exception":
                                has_logging = True
                            if isinstance(func, ast.Name) and func.id == "exception":
                                has_logging = True
                    assert has_logging, (
                        f"except Exception at line {node.lineno} does not call logging.exception()"
                    )

    def test_update_kpis_logs_on_error(self):
        from dashboard import callbacks

        with patch.object(callbacks.queries, "get_saidi_saifi_mensual", side_effect=RuntimeError("db down")):
            with patch("dashboard.callbacks.logging") as mock_logging:
                result = callbacks.update_kpis(None, None, "ALL", "ALL", [])
                mock_logging.exception.assert_called()

    def test_update_kpis_returns_error_state_on_exception(self):
        from dashboard import callbacks

        with patch.object(callbacks.queries, "get_saidi_saifi_mensual", side_effect=RuntimeError("db down")):
            result = callbacks.update_kpis(None, None, "ALL", "ALL", [])
            assert result is not None

    def test_update_trend_logs_on_error(self):
        from dashboard import callbacks

        with patch.object(callbacks.queries, "get_tendencia_12_meses", side_effect=RuntimeError("db down")):
            with patch("dashboard.callbacks.logging") as mock_logging:
                result = callbacks.update_trend(None, None, "ALL")
                mock_logging.exception.assert_called()

    def test_update_ranking_logs_on_error(self):
        from dashboard import callbacks

        with patch.object(callbacks.queries, "get_ranking_subestaciones", side_effect=RuntimeError("db down")):
            with patch("dashboard.callbacks.logging") as mock_logging:
                result = callbacks.update_ranking(None, None, "ALL", "ALL")
                mock_logging.exception.assert_called()

    def test_populate_subestaciones_logs_on_error(self):
        from dashboard import callbacks

        with patch.object(callbacks.queries, "get_distinct_subestaciones", side_effect=RuntimeError("db down")):
            with patch("dashboard.callbacks.logging") as mock_logging:
                result = callbacks.populate_subestaciones(None)
                mock_logging.exception.assert_called()
                assert result == []
