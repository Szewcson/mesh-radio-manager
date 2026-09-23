"""Meshtastic package, generated configuration, and isolated USBFS runner."""

from __future__ import annotations

import datetime as dt
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any, Mapping, Sequence

import yaml

from .assignments import CONFIG_PATH, configuration_lock, load, save, validate
from .errors import ManagerError
from .profiles import effective_meshtastic_config
from .usb import DEV_USB_ROOT, enumerate_devices

MESHTASTIC_BINARY = Path("/usr/bin/meshtasticd")
MESHTASTIC_CONFIG = Path("/etc/meshtasticd/config.yaml")
MESHTASTIC_RUNTIME_CONFIG = Path("/run/mesh-radio-manager/meshtasticd.yaml")
MESHTASTIC_FS_DIR = Path("/var/lib/meshtasticd")
BACKUP_DIR = Path("/var/lib/mesh-radio-manager/backups")
MESHTASTIC_UNIT = "meshtasticd.service"
MESHTASTIC_API_PORT = 4403
MESHTASTIC_WEB_UI_DEFAULT_PORT = 9443
MESHTASTIC_WEB_UI_ROOT = Path("/usr/share/meshtasticd/web")
MESHTASTIC_WEB_UI_KEY = Path("/etc/meshtasticd/ssl/private_key.pem")
MESHTASTIC_WEB_UI_CERTIFICATE = Path("/etc/meshtasticd/ssl/certificate.pem")


def web_ui_settings(data: Mapping[str, Any]) -> dict[str, Any]:
    meshtastic = data.get("meshtastic", {})
    if not isinstance(meshtastic, Mapping):
        raise ManagerError("meshtastic settings must be a mapping")
    configured = meshtastic.get("web_ui", {})
    if not isinstance(configured, Mapping):
        raise ManagerError("meshtastic.web_ui must be a mapping")
    enabled = configured.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ManagerError("meshtastic.web_ui.enabled must be true or false")
    port = configured.get("port", MESHTASTIC_WEB_UI_DEFAULT_PORT)
    if isinstance(port, bool):
        raise ManagerError("meshtastic.web_ui.port must be an integer")
    try:
        port = int(port)
    except (TypeError, ValueError) as error:
        raise ManagerError("meshtastic.web_ui.port must be an integer") from error
    if not 1 <= port <= 65535:
        raise ManagerError("meshtastic.web_ui.port must be in 1..65535")
    return {"enabled": enabled, "port": port}


def _listeners_for_port(output: str, port: int) -> list[str]:
    pattern = re.compile(rf":{re.escape(str(port))}(?:\s|$)")
    return [line for line in output.splitlines() if pattern.search(line)]


def _reserved_web_ui_ports(data: Mapping[str, Any]) -> dict[int, str]:
    reserved = {
        MESHTASTIC_API_PORT: "the Meshtastic TCP API",
        8000: "the openHop web UI",
    }
    manager_web = data.get("web", {})
    if isinstance(manager_web, Mapping):
        candidate = manager_web.get("port", 8001)
        if isinstance(candidate, int) and not isinstance(candidate, bool) and 1 <= candidate <= 65535:
            reserved[candidate] = "the Mesh Radio Manager diagnostics UI"
    return reserved


def validate_web_ui_enable(data: Mapping[str, Any], port: int, listening: str) -> None:
    if port in _reserved_web_ui_ports(data):
        raise ManagerError(f"Meshtastic web UI port {port} conflicts with {_reserved_web_ui_ports(data)[port]}")
    if not MESHTASTIC_WEB_UI_ROOT.is_dir():
        raise ManagerError(f"Meshtastic web UI assets are missing: {MESHTASTIC_WEB_UI_ROOT}")
    existing = _listeners_for_port(listening, port)
    unowned = [line for line in existing if "meshtasticd" not in line]
    if unowned:
        raise ManagerError(
            f"Meshtastic web UI port {port} is already in use: {unowned[0].strip()}"
        )


def set_web_ui(enabled: bool, *, port: int | None = None, listening: str = "") -> tuple[dict[str, Any], dict[str, Any]]:
    """Persist an opt-in web UI setting after validating its port.

    The caller restarts meshtasticd after this function returns.  The setting
    is manager-owned so advanced YAML cannot bypass conflict checks.
    """
    with configuration_lock():
        data = load()
        previous = web_ui_settings(data)
        selected_port = previous["port"] if port is None else port
        if isinstance(selected_port, bool):
            raise ManagerError("Meshtastic web UI port must be an integer")
        try:
            selected_port = int(selected_port)
        except (TypeError, ValueError) as error:
            raise ManagerError("Meshtastic web UI port must be an integer") from error
        if not 1 <= selected_port <= 65535:
            raise ManagerError("Meshtastic web UI port must be in 1..65535")
        if enabled:
            validate_web_ui_enable(data, selected_port, listening)
        data.setdefault("meshtastic", {})["web_ui"] = {"enabled": enabled, "port": selected_port}
        save(data)
        return previous, {"enabled": enabled, "port": selected_port}


def restore_web_ui(settings: Mapping[str, Any]) -> None:
    with configuration_lock():
        data = load()
        restored = web_ui_settings({"meshtastic": {"web_ui": settings}})
        data.setdefault("meshtastic", {})["web_ui"] = restored
        save(data)


def web_ui_status(data: Mapping[str, Any], listening: str) -> dict[str, Any]:
    settings = web_ui_settings(data)
    listeners = _listeners_for_port(listening, settings["port"])
    return {
        **settings,
        "root": str(MESHTASTIC_WEB_UI_ROOT),
        "url": f"https://<LXC-IP>:{settings['port']}",
        "listening": bool(listeners),
        "listeners": listeners,
    }


def apply_web_ui_settings(config: dict[str, Any], settings: Mapping[str, Any]) -> dict[str, Any]:
    """Add only manager-owned web server settings to an effective config."""
    ui = web_ui_settings({"meshtastic": {"web_ui": settings}})
    if ui["enabled"]:
        config["Webserver"] = {
            "Port": ui["port"],
            "RootPath": str(MESHTASTIC_WEB_UI_ROOT),
            "SSLKey": str(MESHTASTIC_WEB_UI_KEY),
            "SSLCert": str(MESHTASTIC_WEB_UI_CERTIFICATE),
        }
    return config


def installed(binary: Path = MESHTASTIC_BINARY) -> bool:
    return binary.is_file() and os.access(binary, os.X_OK)


def version(binary: Path = MESHTASTIC_BINARY) -> str | None:
    if not installed(binary):
        return None
    for option in ("--version", "-v"):
        try:
            result = subprocess.run([str(binary), option], text=True, capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0:
            return (result.stdout or result.stderr).strip().splitlines()[0]
    return "installed (version query unsupported)"


def _atomic_yaml(path: Path, data: Mapping[str, Any]) -> None:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(yaml.safe_dump(dict(data), default_flow_style=False, sort_keys=False), encoding="utf-8")
    temporary.replace(path)


def prepare_runtime_config(
    *, manager_config: Path = CONFIG_PATH,
    destination: Path = MESHTASTIC_RUNTIME_CONFIG,
) -> Path:
    with configuration_lock():
        data = load(manager_config)
        resolved = validate(data, enumerate_devices(), require_present=True)
        device = resolved.get("meshtastic")
        assignment = data.get("assignments", {}).get("meshtastic")
        if device is None or not isinstance(assignment, Mapping):
            raise ManagerError("No radio is assigned to meshtasticd")
        advanced = data.get("meshtastic", {}).get("advanced", {})
        effective = effective_meshtastic_config(assignment, device, advanced)
        apply_web_ui_settings(effective, web_ui_settings(data))
        _atomic_yaml(destination, effective)
    return destination


def backup_config(source: Path = MESHTASTIC_CONFIG, backup_dir: Path = BACKUP_DIR) -> Path | None:
    if not source.exists():
        return None
    backup_dir.mkdir(mode=0o750, parents=True, exist_ok=True)
    stamp = dt.datetime.now(tz=dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    target = backup_dir / f"{source.name}.{stamp}.bak"
    shutil.copy2(source, target)
    return target


def restore_config(backup: Path, destination: Path = MESHTASTIC_CONFIG) -> None:
    if not backup.is_file():
        raise ManagerError(f"Backup does not exist: {backup}")
    destination.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    shutil.copy2(backup, destination)


def package_versions() -> dict[str, str | None]:
    def apt(argument: str) -> str | None:
        try:
            result = subprocess.run(["apt-cache", "policy", "meshtasticd"], text=True, capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            return None
        for line in result.stdout.splitlines():
            if line.strip().startswith(argument):
                return line.split(":", 1)[1].strip() or None
        return None
    return {"installed": apt("Installed"), "candidate": apt("Candidate")}


def upgrade(*, assume_yes: bool = False) -> Path | None:
    versions = package_versions()
    if not versions["candidate"]:
        raise ManagerError("No meshtasticd apt candidate is available")
    if not assume_yes:
        raise ManagerError(
            f"meshtasticd installed={versions['installed'] or 'none'}, candidate={versions['candidate']}; "
            "rerun with --yes after reviewing the version"
        )
    backup = backup_config()
    try:
        result = subprocess.run(["apt-get", "install", "--yes", "meshtasticd"], text=True, timeout=15 * 60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ManagerError(f"meshtasticd upgrade failed: {error}") from error
    if result.returncode:
        raise ManagerError("apt-get failed upgrading meshtasticd; configuration backup was retained")
    return backup


def _atomic_text(path: Path, content: str, mode: int = 0o644) -> None:
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def install_package(channel: str = "beta") -> dict[str, str | None]:
    """Install from Meshtastic's upstream OBS repository, never silently start it."""
    if os.geteuid() != 0:
        raise ManagerError("Meshtastic installation must run as root")
    if channel not in {"alpha", "beta"}:
        raise ManagerError("Meshtastic channel must be alpha or beta")
    if shutil.which("gpg") is None:
        raise ManagerError(
            "gnupg is required to import the Meshtastic apt key; run: apt-get install -y gnupg"
        )
    # The Debian 13 suite and repository path are the current upstream method.
    base = f"https://download.opensuse.org/repositories/network:/Meshtastic:/{channel}/Debian_13"
    keyring = Path(f"/etc/apt/keyrings/meshtastic-{channel}.gpg")
    source = Path(f"/etc/apt/sources.list.d/meshtastic-{channel}.list")
    keyring.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix="meshtastic-release-key-", dir="/tmp")
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        fetch = subprocess.run(
            ["curl", "--fail", "--location", "--silent", "--show-error", f"{base}/Release.key", "--output", str(temporary)],
            text=True,
            capture_output=True,
            timeout=60,
        )
        if fetch.returncode:
            raise ManagerError(f"Could not retrieve Meshtastic repository key: {fetch.stderr.strip()}")
        dearmor = subprocess.run(
            ["gpg", "--dearmor", "--yes", "--output", str(keyring), str(temporary)],
            text=True,
            capture_output=True,
            timeout=60,
        )
        if dearmor.returncode:
            raise ManagerError(f"Could not install Meshtastic repository key: {dearmor.stderr.strip()}")
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ManagerError(f"Could not prepare Meshtastic repository: {error}") from error
    finally:
        temporary.unlink(missing_ok=True)
    _atomic_text(source, f"deb [signed-by={keyring}] {base}/ /\n")
    # Package post-install hooks must not obtain an unassigned first look at a
    # CH341. The temporary runtime mask is lifted after installation; a
    # manager-installed drop-in then guards every explicit start.
    masked = subprocess.run(["systemctl", "mask", "--runtime", MESHTASTIC_UNIT], text=True, capture_output=True, timeout=30)
    if masked.returncode:
        raise ManagerError(f"Could not temporarily mask meshtasticd: {masked.stderr.strip()}")
    try:
        for command in (["apt-get", "update"], ["apt-get", "install", "--yes", "meshtasticd"]):
            try:
                result = subprocess.run(command, text=True, timeout=15 * 60)
            except (OSError, subprocess.TimeoutExpired) as error:
                raise ManagerError(f"{' '.join(command)} failed: {error}") from error
            if result.returncode:
                raise ManagerError(f"{' '.join(command)} failed")
    finally:
        subprocess.run(["systemctl", "unmask", "--runtime", MESHTASTIC_UNIT], text=True, capture_output=True, timeout=30)
    return package_versions()


def _mount(arguments: Sequence[str]) -> None:
    result = subprocess.run(["mount", *arguments], text=True, capture_output=True)
    if result.returncode:
        raise ManagerError(f"USB isolation mount failed: {result.stderr.strip()}")


def isolate_assigned_usb(device_node: Path, root: Path = DEV_USB_ROOT) -> None:
    """Expose exactly one USBFS device in the service's private mount namespace.

    This is called only by the root systemd wrapper with `PrivateMounts=yes`.
    It does not alter the host mount namespace. A serial selector is still
    supplied where Meshtastic supports it; isolation is the safe fallback for
    a port-identified/singleton CH341 device.
    """
    if not device_node.is_char_device():
        raise ManagerError(f"Assigned USBFS node is unavailable: {device_node}")
    stash = Path("/run/mesh-radio-manager/usb-stash")
    stash.mkdir(mode=0o700, parents=True, exist_ok=True)
    isolated = stash / f"{device_node.parent.name}-{device_node.name}"
    isolated.touch(exist_ok=True)
    _mount(["--bind", str(device_node), str(isolated)])
    _mount(["-t", "tmpfs", "tmpfs", str(root)])
    target_parent = root / device_node.parent.name
    target_parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    target = target_parent / device_node.name
    target.touch(exist_ok=True)
    _mount(["--bind", str(isolated), str(target)])


def run_daemon(arguments: Sequence[str] = ()) -> int:
    """Systemd entry point; validates assignment immediately before exec."""
    if os.geteuid() != 0:
        raise ManagerError("meshtasticd wrapper must run as root in a private mount namespace")
    config = prepare_runtime_config()
    data = load()
    device = validate(data, enumerate_devices(), require_present=True)["meshtastic"]
    if not device.serial:
        isolate_assigned_usb(device.device_node)
    command = [str(MESHTASTIC_BINARY), "--config", str(config), "--fsdir", str(MESHTASTIC_FS_DIR), *arguments]
    os.execv(command[0], command)
    return 127
