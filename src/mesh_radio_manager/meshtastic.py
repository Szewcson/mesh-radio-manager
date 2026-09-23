"""Meshtastic package, generated configuration, and isolated USBFS runner."""

from __future__ import annotations

import datetime as dt
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import Any, Mapping, Sequence

import yaml

from .assignments import CONFIG_PATH, configuration_lock, load, validate
from .errors import ManagerError
from .profiles import effective_meshtastic_config
from .usb import DEV_USB_ROOT, enumerate_devices

MESHTASTIC_BINARY = Path("/usr/bin/meshtasticd")
MESHTASTIC_CONFIG = Path("/etc/meshtasticd/config.yaml")
MESHTASTIC_RUNTIME_CONFIG = Path("/run/mesh-radio-manager/meshtasticd.yaml")
MESHTASTIC_FS_DIR = Path("/var/lib/meshtasticd")
BACKUP_DIR = Path("/var/lib/mesh-radio-manager/backups")
MESHTASTIC_UNIT = "meshtasticd.service"


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
        _atomic_yaml(destination, effective_meshtastic_config(assignment, device, advanced))
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
