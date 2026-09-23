"""Persistent assignments with a single lock and atomic replacement.

The same advisory lock covers administrator writes and service-start reads.
This prevents a service from seeing a half-written mapping or a simultaneous
assignment operation from handing one radio to two daemons.
"""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import tempfile
from typing import Any, Iterator, Mapping

import yaml

from .errors import ManagerError
from .usb import UsbDevice

CONFIG_DIR = Path("/etc/mesh-radio-manager")
CONFIG_PATH = CONFIG_DIR / "config.yaml"
LOCK_PATH = Path("/run/mesh-radio-manager/assignments.lock")
ROLES = ("openhop", "meshtastic")


def _default() -> dict[str, Any]:
    return {
        "version": 1,
        "assignments": {},
        "meshtastic": {"channel": "beta", "advanced": {}},
        "web": {"host": "127.0.0.1", "port": 8001},
    }


@contextmanager
def configuration_lock(lock_path: Path = LOCK_PATH) -> Iterator[None]:
    lock_path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _atomic_write(path: Path, content: str, mode: int = 0o640) -> None:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
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


def load(path: Path = CONFIG_PATH) -> dict[str, Any]:
    if not path.exists():
        return _default()
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as error:
        raise ManagerError(f"Cannot read manager configuration: {error}") from error
    if not isinstance(data, dict) or data.get("version", 1) != 1:
        raise ManagerError("Manager configuration must be a version 1 YAML mapping")
    result = _default()
    result.update(data)
    if not isinstance(result["assignments"], dict):
        raise ManagerError("assignments must be a YAML mapping")
    return result


def save(data: Mapping[str, Any], path: Path = CONFIG_PATH) -> None:
    validate(data, require_present=False)
    _atomic_write(path, yaml.safe_dump(dict(data), default_flow_style=False, sort_keys=False))


def normalize_identity(identity: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(identity, Mapping):
        raise ManagerError("USB identity must be a mapping")
    def hex_id(value: Any, default: str) -> int:
        # A previously-normalized identity carries integers. Reinterpreting
        # decimal `6790` as hexadecimal was an ambiguity bug and could make a
        # valid radio appear missing between validation steps.
        if value is None:
            value = default
        if isinstance(value, bool):
            raise ValueError("boolean is not a USB ID")
        return int(value) if isinstance(value, int) else int(str(value), 16)

    try:
        vid = hex_id(identity.get("vid"), "1a86")
        pid = hex_id(identity.get("pid"), "5512")
    except ValueError as error:
        raise ManagerError("USB identity vid and pid must be hexadecimal values") from error
    if not 0 <= vid <= 0xFFFF or not 0 <= pid <= 0xFFFF:
        raise ManagerError("USB identity vid and pid must fit in 16 bits")
    result: dict[str, Any] = {"vid": vid, "pid": pid}
    for key in ("serial", "port_path", "usb_path"):
        value = str(identity.get(key) or "").strip()
        if value:
            result[key] = value
    if identity.get("unidentified") is True:
        result["unidentified"] = True
    identifying = [key for key in ("serial", "port_path", "usb_path", "unidentified") if key in result]
    if len(identifying) != 1:
        raise ManagerError(
            "USB identity needs exactly one of serial, port_path, usb_path, or unidentified; "
            "bus/address is never a persistent identity"
        )
    return result


def _matching(identity: Mapping[str, Any], devices: list[UsbDevice]) -> list[UsbDevice]:
    normal = normalize_identity(identity)
    matches = [d for d in devices if d.vid == normal["vid"] and d.pid == normal["pid"]]
    if "serial" in normal:
        return [d for d in matches if d.serial == normal["serial"]]
    if "port_path" in normal:
        return [d for d in matches if d.port_path == normal["port_path"]]
    if "usb_path" in normal:
        return [d for d in matches if d.path == normal["usb_path"]]
    return [d for d in matches if not d.serial and not d.port_path]


def resolve(identity: Mapping[str, Any], devices: list[UsbDevice]) -> UsbDevice:
    normal = normalize_identity(identity)
    matches = _matching(normal, devices)
    label = normal.get("serial") or normal.get("port_path") or normal.get("usb_path") or "unidentified"
    if not matches:
        raise ManagerError(f"Assigned USB radio {label!r} is not present")
    if len(matches) != 1:
        raise ManagerError(
            f"Assignment {label!r} matches {len(matches)} radios; refusing to select a device ambiguously"
        )
    return matches[0]


def _identity_key(identity: Mapping[str, Any]) -> tuple[Any, ...]:
    normal = normalize_identity(identity)
    kind = next(key for key in ("serial", "port_path", "usb_path", "unidentified") if key in normal)
    return normal["vid"], normal["pid"], kind, normal[kind]


def validate(data: Mapping[str, Any], devices: list[UsbDevice] | None = None, *, require_present: bool = True) -> dict[str, UsbDevice]:
    assignments = data.get("assignments", {})
    if not isinstance(assignments, Mapping):
        raise ManagerError("assignments must be a mapping")
    declared: dict[tuple[Any, ...], str] = {}
    resolved: dict[str, UsbDevice] = {}
    for role, assignment in assignments.items():
        if role not in ROLES:
            raise ManagerError(f"Unknown service role {role!r}")
        if not isinstance(assignment, Mapping):
            raise ManagerError(f"Assignment for {role} must be a mapping")
        key = _identity_key(assignment.get("identity", {}))
        if key in declared:
            raise ManagerError(
                f"One USB identity is assigned to both {declared[key]} and {role}; this is unsafe"
            )
        declared[key] = role
        if require_present:
            if devices is None:
                raise ManagerError("Device list is required for runtime validation")
            resolved[role] = resolve(assignment["identity"], devices)
    occupied: dict[tuple[int, int, str], str] = {}
    for role, device in resolved.items():
        current = (device.bus, device.address, device.path)
        if current in occupied:
            raise ManagerError(
                f"Connected radio {device.path} resolves to both {occupied[current]} and {role}; refusing start"
            )
        occupied[current] = role
    return resolved


def identity_from_device(device: UsbDevice, all_devices: list[UsbDevice]) -> dict[str, Any]:
    identity: dict[str, Any] = {"vid": f"{device.vid:04x}", "pid": f"{device.pid:04x}"}
    if device.serial:
        identity["serial"] = device.serial
    elif device.port_path:
        identity["port_path"] = device.port_path
    else:
        peers = [d for d in all_devices if (d.vid, d.pid) == (device.vid, device.pid) and not d.serial and not d.port_path]
        if len(peers) != 1:
            raise ManagerError(
                "This radio has no serial or stable topology and more than one indistinguishable "
                "VID:PID peer exists; assignment is unsafe"
            )
        identity["unidentified"] = True
    return identity


def assign(
    role: str,
    device: UsbDevice,
    profile: str,
    devices: list[UsbDevice],
    path: Path = CONFIG_PATH,
    lora: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if role not in ROLES:
        raise ManagerError(f"Unknown service role {role!r}")
    with configuration_lock():
        data = load(path)
        assignments = data.setdefault("assignments", {})
        assignment: dict[str, Any] = {"identity": identity_from_device(device, devices), "profile": profile}
        if lora is not None:
            assignment["lora"] = dict(lora)
        assignments[role] = assignment
        resolved = validate(data, devices, require_present=True)
        if role == "meshtastic":
            # Generic CH341 profiles must prove their GPIO mapping before an
            # unsafe/incomplete assignment can be written to disk.
            from .profiles import effective_meshtastic_config

            effective_meshtastic_config(assignment, resolved[role], data.get("meshtastic", {}).get("advanced", {}))
        save(data, path)
        return data
