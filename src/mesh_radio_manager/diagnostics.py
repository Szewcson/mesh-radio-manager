"""Issue-safe diagnostic report with recursive secret redaction."""

from __future__ import annotations

import os
from pathlib import Path
import re
from typing import Any, Mapping

from . import __version__
from .assignments import CONFIG_PATH, load
from .meshtastic import MESHTASTIC_UNIT, installed as meshtastic_installed, version as meshtastic_version
from .openhop import OPENHOP_UNIT, metadata as openhop_metadata
from .services import listening_ports, logs, state
from .usb import enumerate_devices

SECRET_RE = re.compile(r"password|passphrase|psk|token|api.?key|secret|private.?key", re.IGNORECASE)


def redact(value: Any, key: str = "") -> Any:
    if SECRET_RE.search(key):
        return "<redacted>"
    if isinstance(value, Mapping):
        return {str(item_key): redact(item_value, str(item_key)) for item_key, item_value in value.items()}
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def _os_release() -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        lines = Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
    except OSError:
        return result
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value.strip('"')
    return result


def _container() -> dict[str, Any]:
    environment = os.environ.get("container")
    return {"container_environment": environment, "docker_marker": Path("/.dockerenv").exists()}


def report() -> dict[str, Any]:
    config = load(CONFIG_PATH)
    devices = enumerate_devices()
    assignment_roles = config.get("assignments", {})
    assigned_keys: dict[str, str] = {}
    for role, assignment in assignment_roles.items():
        if isinstance(assignment, Mapping):
            identity = assignment.get("identity", {})
            if isinstance(identity, Mapping):
                for device in devices:
                    if identity.get("serial") and device.serial == identity.get("serial"):
                        assigned_keys[device.path] = str(role)
                    elif identity.get("port_path") and device.port_path == identity.get("port_path"):
                        assigned_keys[device.path] = str(role)
    dropins = {
        "openhop": "/etc/systemd/system/openhop-repeater.service.d/20-mesh-radio-manager.conf",
        "meshtastic": "/etc/systemd/system/meshtasticd.service.d/20-mesh-radio-manager.conf",
    }
    return redact(
        {
            "manager_version": __version__,
            "os": _os_release(),
            "container": _container(),
            "openhop": openhop_metadata(),
            "meshtasticd": {"installed": meshtastic_installed(), "version": meshtastic_version()},
            "services": {OPENHOP_UNIT: state(OPENHOP_UNIT), MESHTASTIC_UNIT: state(MESHTASTIC_UNIT)},
            "devices": [device.public_dict(assigned_keys.get(device.path)) for device in devices],
            "assignments": config.get("assignments", {}),
            "listening_ports": listening_ports(),
            "dropins": {name: {"path": path, "installed": Path(path).exists()} for name, path in dropins.items()},
            "recent_errors": {OPENHOP_UNIT: logs(OPENHOP_UNIT, 30), MESHTASTIC_UNIT: logs(MESHTASTIC_UNIT, 30)},
        }
    )
