"""
Tests for docker/powder/monitoring/scripts/seed-uptime-kuma.py
"""

import sys
from unittest.mock import MagicMock, call, patch

import pytest

from conftest import load_seed_module


# ── Module loading / env validation ──────────────────────────────────────────

def test_module_loads_with_required_env_vars():
    mod = load_seed_module()
    assert mod.TAILNET == "testtail"
    assert mod.TS == "testtail.ts.net"


def test_upk_url_defaults_to_tailnet_hostname():
    mod = load_seed_module()
    assert mod.UPK_URL == "https://uptime-kuma.testtail.ts.net"


def test_upk_url_can_be_overridden():
    mod = load_seed_module({"UPK_URL": "https://custom.example.com"})
    assert mod.UPK_URL == "https://custom.example.com"


def test_main_exits_when_required_env_vars_missing():
    mod = load_seed_module({"TAILNET": "", "UPK_USER": "", "UPK_PASS": ""})
    with pytest.raises(SystemExit):
        mod.main()


def test_main_exits_when_only_tailnet_missing():
    mod = load_seed_module({"TAILNET": ""})
    with pytest.raises(SystemExit):
        mod.main()


# ── GROUPS structure ──────────────────────────────────────────────────────────

def test_groups_contain_expected_server_keys():
    mod = load_seed_module()
    assert set(mod.GROUPS.keys()) == {"pancake", "charm", "powder", "external", "dns"}


def test_groups_urls_embed_tailnet():
    mod = load_seed_module({"TAILNET": "mynet"})
    urls = [m.get("url", "") for m in mod.GROUPS["pancake"]]
    assert all("mynet.ts.net" in u for u in urls if u)


def test_pancake_group_includes_plex():
    mod = load_seed_module()
    names = [m["name"] for m in mod.GROUPS["pancake"]]
    assert "Plex" in names


def test_charm_group_includes_adguard():
    mod = load_seed_module()
    names = [m["name"] for m in mod.GROUPS["charm"]]
    assert "AdGuard Home" in names


def test_dns_group_monitors_use_dns_type():
    mod = load_seed_module()
    for monitor in mod.GROUPS["dns"]:
        assert monitor["type"] == mod.MonitorType.DNS


# ── add_conditional_monitors ─────────────────────────────────────────────────

def test_add_conditional_monitors_adds_mqtt_monitor_when_creds_set():
    mod = load_seed_module({"MQTT_USER": "user", "MQTT_PASS": "pass"})
    mod.add_conditional_monitors()
    names = [m["name"] for m in mod.GROUPS["charm"]]
    assert "Mosquitto (MQTT)" in names
    assert "Mosquitto (TCP)" not in names


def test_add_conditional_monitors_falls_back_to_tcp_without_mqtt_creds():
    mod = load_seed_module()  # MQTT_USER / MQTT_PASS not set
    mod.add_conditional_monitors()
    names = [m["name"] for m in mod.GROUPS["charm"]]
    assert "Mosquitto (TCP)" in names
    assert "Mosquitto (MQTT)" not in names


def test_add_conditional_monitors_adds_mysql_monitor_when_creds_set():
    mod = load_seed_module({"MYSQL_USER": "root", "MYSQL_PASS": "secret"})
    mod.add_conditional_monitors()
    names = [m["name"] for m in mod.GROUPS["charm"]]
    assert "MySQL (charm)" in names
    assert "MySQL (TCP)" not in names


def test_add_conditional_monitors_falls_back_to_tcp_without_mysql_creds():
    mod = load_seed_module()
    mod.add_conditional_monitors()
    names = [m["name"] for m in mod.GROUPS["charm"]]
    assert "MySQL (TCP)" in names
    assert "MySQL (charm)" not in names


def test_mysql_connection_string_uses_custom_db():
    mod = load_seed_module(
        {"MYSQL_USER": "root", "MYSQL_PASS": "secret", "MYSQL_DB": "mydb"}
    )
    mod.add_conditional_monitors()
    mysql_monitor = next(
        m for m in mod.GROUPS["charm"] if m.get("name") == "MySQL (charm)"
    )
    assert "mydb" in mysql_monitor["databaseConnectionString"]


# ── main() — idempotency and CRUD behaviour ───────────────────────────────────

def _make_api_mock(existing_names=None):
    """Return a mock UptimeKumaApi context manager with pre-populated monitors."""
    existing = {name: i + 1 for i, name in enumerate(existing_names or [])}
    monitors = [{"name": n, "id": i} for n, i in existing.items()]

    api = MagicMock()
    api.get_monitors.return_value = monitors
    api.add_monitor.return_value = {"monitorID": 999}

    ctx = MagicMock()
    ctx.__enter__ = MagicMock(return_value=api)
    ctx.__exit__ = MagicMock(return_value=False)
    return ctx, api


def test_main_creates_groups_and_monitors():
    mod = load_seed_module()
    ctx, api = _make_api_mock()

    with patch.object(mod, "UptimeKumaApi", return_value=ctx):
        mod.main()

    assert api.add_monitor.called
    # At minimum one group per server key should be created
    group_calls = [
        c for c in api.add_monitor.call_args_list
        if c.kwargs.get("type") == mod.MonitorType.GROUP
    ]
    assert len(group_calls) == len(mod.GROUPS)


def test_main_skips_monitors_that_already_exist():
    mod = load_seed_module()
    # Pre-populate with every monitor and group that main() would create
    mod.add_conditional_monitors()
    all_names = list(mod.GROUPS.keys())
    for monitors in mod.GROUPS.values():
        all_names.extend(m["name"] for m in monitors)

    ctx, api = _make_api_mock(existing_names=all_names)

    with patch.object(mod, "UptimeKumaApi", return_value=ctx):
        mod.main()

    api.add_monitor.assert_not_called()


def test_main_reset_deletes_existing_monitors_before_creating():
    mod = load_seed_module()
    ctx, api = _make_api_mock(existing_names=["OldGroup", "OldMonitor"])

    original_argv = sys.argv[:]
    sys.argv = ["seed-uptime-kuma.py", "--reset"]
    try:
        with patch.object(mod, "UptimeKumaApi", return_value=ctx), \
             patch.object(mod, "RESET", True):
            mod.main()
    finally:
        sys.argv = original_argv

    assert api.delete_monitor.called


def test_main_continues_after_failed_group_creation():
    """A failed group should not abort the entire run."""
    mod = load_seed_module()
    ctx, api = _make_api_mock()
    api.add_monitor.side_effect = Exception("API error")

    with patch.object(mod, "UptimeKumaApi", return_value=ctx):
        # Should not raise
        mod.main()
