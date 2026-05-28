"""Tests for dashboard/components/filters.py — no FormGroup, DB-populated options."""

import inspect

import pytest


class TestNoFormGroup:
    """dbc.FormGroup is deprecated in dash-bootstrap-components >= 1.5.0."""

    def test_filters_bar_has_no_formgroup(self):
        from dashboard.components import filters

        source = inspect.getsource(filters)
        assert "FormGroup" not in source, "filters.py still uses deprecated dbc.FormGroup"

    def test_drilldown_has_no_formgroup(self):
        from dashboard.layouts import drilldown

        source = inspect.getsource(drilldown)
        assert "FormGroup" not in source, "drilldown.py still uses deprecated dbc.FormGroup"

    def test_filters_bar_returns_row(self):
        import dash_bootstrap_components as dbc
        from dashboard.components.filters import filters_bar

        result = filters_bar()
        assert isinstance(result, dbc.Row)

    def test_filters_bar_has_col_children(self):
        import dash_bootstrap_components as dbc
        from dashboard.components.filters import filters_bar

        result = filters_bar()
        for child in result.children:
            assert isinstance(child, dbc.Col)


class TestDynamicOptions:
    """Filter dropdowns must be populated from DB dimension tables."""

    def test_sector_dropdown_accepts_options(self):
        from dashboard.components.filters import sector_dropdown

        sectors = ["Norte", "Sur", "Este"]
        component = sector_dropdown(sectors)
        option_values = [o["value"] for o in component.options]
        assert "Norte" in option_values
        assert "Sur" in option_values

    def test_criticality_dropdown_accepts_options(self):
        from dashboard.components.filters import criticality_dropdown

        levels = ["ALTO", "MEDIO", "BAJO"]
        component = criticality_dropdown(levels)
        option_values = [o["value"] for o in component.options]
        assert "ALTO" in option_values

    def test_criticality_dropdown_has_all_option(self):
        from dashboard.components.filters import criticality_dropdown

        component = criticality_dropdown(["ALTO"])
        option_values = [o["value"] for o in component.options]
        assert "ALL" in option_values
