"""Non-invasive adapter for an externally-installed upstream openHop."""

from __future__ import annotations

import copy
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Any, Mapping

import yaml

from .assignments import CONFIG_PATH, configuration_lock, load, validate
from .errors import ManagerError
from .usb import enumerate_devices

OPENHOP_CHECKOUT = Path("/root/openhop-repeater")
OPENHOP_CONFIG = Path("/etc/openhop_repeater/config.yaml")
# Previous releases started openHop with a generated configuration in /run.
# That made normal dashboard saves disappear at the next restart.  The service
# now starts against OPENHOP_CONFIG, which is the upstream persistent path.
RUNTIME_CONFIG = Path("/run/mesh-radio-manager/openhop-config.yaml")
OPENHOP_UNIT = "openhop-repeater.service"


def installed(checkout: Path = OPENHOP_CHECKOUT, config: Path = OPENHOP_CONFIG) -> bool:
    return checkout.is_dir() and config.is_file()


def _git(checkout: Path, *args: str) -> str | None:
    if not checkout.is_dir():
        return None
    try:
        result = subprocess.run(["git", "-C", str(checkout), *args], text=True, capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def metadata(checkout: Path = OPENHOP_CHECKOUT, config: Path = OPENHOP_CONFIG) -> dict[str, Any]:
    branch = _git(checkout, "branch", "--show-current")
    commit = _git(checkout, "rev-parse", "--short", "HEAD")
    dirty = _git(checkout, "status", "--porcelain")
    return {
        "installed": installed(checkout, config),
        "checkout": str(checkout),
        "branch": branch,
        "commit": commit,
        "clean": dirty == "" if dirty is not None else False,
        "dirty_paths": dirty.splitlines() if dirty else [],
    }


def _load_yaml(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as error:
        raise ManagerError(f"Cannot read openHop configuration {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManagerError("openHop configuration must be a YAML mapping")
    return value


def _atomic_write_yaml(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    try:
        existing = path.stat()
    except FileNotFoundError:
        existing = None
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            yaml.safe_dump(dict(value), output, default_flow_style=False, sort_keys=False)
            output.flush()
            os.fsync(output.fileno())
        if existing is None:
            os.chmod(temporary, 0o640)
        else:
            os.chown(temporary, existing.st_uid, existing.st_gid)
            os.chmod(temporary, existing.st_mode & 0o7777)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _ch341_selector(device: Any) -> dict[str, Any]:
    # Runtime values only. USB address is intentionally not copied into the
    # manager assignment database.
    return {
        "vid": device.vid,
        "pid": device.pid,
        "bus": device.bus,
        "address": device.address,
        "serial_number": device.serial,
    }


def prepare_persistent_config(
    *,
    source: Path = OPENHOP_CONFIG,
    manager_config: Path = CONFIG_PATH,
) -> Path:
    """Persist only the resolved CH341 selector in openHop's real config.

    openHop's dashboard owns credentials, API tokens, and all ordinary
    configuration.  It saves them to ``source``.  A runtime-only overlay made
    those saves vanish, so the manager updates just its dynamic USB selector
    in that same canonical file immediately before each service start.
    """
    if not source.exists():
        raise ManagerError("Official openHop configuration is missing; install openHop first")
    with configuration_lock():
        data = load(manager_config)
        resolved = validate(data, enumerate_devices(), require_present=True)
        device = resolved.get("openhop")
        if device is None:
            raise ManagerError("No radio is assigned to openHop")
        output = copy.deepcopy(_load_yaml(source))
        selector = _ch341_selector(device)
        output["ch341"] = selector
        radios = output.get("radios")
        if isinstance(radios, list):
            for radio in radios:
                if isinstance(radio, dict) and radio.get("radio_type") == "sx1262_ch341":
                    radio["ch341"] = selector
        _atomic_write_yaml(source, output)
    return source


def migrate_newer_runtime_config(
    *,
    source: Path = OPENHOP_CONFIG,
    runtime: Path = RUNTIME_CONFIG,
) -> bool:
    """Recover a newer legacy runtime config once during an upgrade.

    Older manager releases instructed openHop to save its dashboard changes to
    ``runtime``.  If that file is newer than the canonical config, preserve
    those user changes before switching the service back to ``source``.
    """
    if not runtime.is_file():
        return False
    try:
        if source.exists() and runtime.stat().st_mtime_ns <= source.stat().st_mtime_ns:
            return False
    except OSError as error:
        raise ManagerError(f"Cannot compare openHop configuration timestamps: {error}") from error
    _atomic_write_yaml(source, _load_yaml(runtime))
    return True
