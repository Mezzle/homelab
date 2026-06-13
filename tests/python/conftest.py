"""
pytest configuration for seed-uptime-kuma tests.

The script uses a hyphen in its filename and imports uptime_kuma_api (not
installed in CI). This module mocks the third-party dependency and provides
a helper for loading the script as a module with controlled env vars.
"""

import importlib.util
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

SCRIPT_PATH = (
    Path(__file__).parent.parent.parent
    / "docker/powder/monitoring/scripts/seed-uptime-kuma.py"
)


class _MockMonitorType:
    GROUP = "group"
    HTTP = "http"
    KEYWORD = "keyword"
    PING = "ping"
    PORT = "port"
    DNS = "dns"
    MQTT = "mqtt"
    MYSQL = "mysql"
    JSON_QUERY = "json_query"


def _make_uptime_kuma_mock():
    mock_module = MagicMock()
    mock_module.MonitorType = _MockMonitorType
    mock_module.UptimeKumaApi = MagicMock()
    return mock_module


def load_seed_module(env_overrides=None):
    """
    Import seed-uptime-kuma.py with controlled env vars and the
    uptime_kuma_api dependency mocked out.

    Returns the loaded module object.
    """
    env = {
        "TAILNET": "testtail",
        "UPK_USER": "admin",
        "UPK_PASS": "password",
        **(env_overrides or {}),
    }

    # Evict any cached version so module-level globals rebuild from env
    sys.modules.pop("seed_uptime_kuma", None)

    uptime_mock = _make_uptime_kuma_mock()

    with pytest.MonkeyPatch.context() as mp:
        for k, v in env.items():
            mp.setenv(k, v)
        # Clear vars not in env so tests start from a clean slate
        for var in ("MQTT_USER", "MQTT_PASS", "MYSQL_USER", "MYSQL_PASS", "MYSQL_DB"):
            if var not in env:
                mp.delenv(var, raising=False)

        with (
            __import__("unittest.mock", fromlist=["patch"]).patch.dict(
                sys.modules, {"uptime_kuma_api": uptime_mock}
            )
        ):
            spec = importlib.util.spec_from_file_location("seed_uptime_kuma", SCRIPT_PATH)
            mod = importlib.util.module_from_spec(spec)
            sys.modules["seed_uptime_kuma"] = mod
            spec.loader.exec_module(mod)

    return mod


@pytest.fixture
def seed(monkeypatch):
    """Fixture that loads the module with default test env vars."""
    return load_seed_module()
