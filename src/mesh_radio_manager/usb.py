"""USB discovery and stable identity helpers.

Linux bus and device addresses are runtime observations, not persistent device
identity.  sysfs gives us USB descriptor values and the physical port chain
without depending on a tty device or `lsusb` being installed.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import os
from pathlib import Path
import re
from typing import Any

from .errors import ManagerError

SYS_USB_ROOT = Path("/sys/bus/usb/devices")
DEV_USB_ROOT = Path("/dev/bus/usb")
TOPOLOGY_RE = re.compile(r"^\d+-\d+(?:\.\d+)*$")


@dataclass(frozen=True)
class UsbDevice:
    vid: int
    pid: int
    bus: int
    address: int
    path: str
    port_path: str | None = None
    serial: str | None = None
    manufacturer: str | None = None
    product: str | None = None
    driver: str | None = None

    @property
    def device_node(self) -> Path:
        return DEV_USB_ROOT / f"{self.bus:03d}" / f"{self.address:03d}"

    @property
    def selector(self) -> str:
        if self.serial:
            return f"serial:{self.serial}"
        if self.port_path:
            return f"port:{self.port_path}"
        return f"path:{self.path}"

    @property
    def stable_key(self) -> str:
        if self.serial:
            return f"serial:{self.vid:04x}:{self.pid:04x}:{self.serial}"
        if self.port_path:
            return f"port:{self.vid:04x}:{self.pid:04x}:{self.port_path}"
        return f"unidentified:{self.vid:04x}:{self.pid:04x}"

    @property
    def stability_warning(self) -> str | None:
        if self.serial:
            return None
        if self.port_path:
            return "No USB serial: controller/physical port topology is used as identity."
        return (
            "No USB serial or stable controller topology: this radio may be assigned only "
            "when it is the sole matching unidentifiable device."
        )

    def public_dict(self, assigned_service: str | None = None) -> dict[str, Any]:
        result = asdict(self)
        result.update(
            {
                "vid": f"{self.vid:04x}",
                "pid": f"{self.pid:04x}",
                "device_node": str(self.device_node),
                "selector": self.selector,
                "stable_key": self.stable_key,
                "stability_warning": self.stability_warning,
                "assigned_service": assigned_service,
            }
        )
        return result


def _read_text(path: Path) -> str | None:
    try:
        value = path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return None
    return value or None


def _read_int(path: Path, base: int = 10) -> int | None:
    raw = _read_text(path)
    try:
        return int(raw, base) if raw is not None else None
    except ValueError:
        return None


def _driver(entry: Path) -> str | None:
    try:
        return Path(os.path.realpath(entry / "driver")).name
    except OSError:
        return None


def _stable_port_path(entry: Path) -> str | None:
    """Return controller ancestry plus port chain, excluding transient bus number.

    Example: `/devices/pci0000:00/.../usb3/3-2.1` becomes
    `pci0000:00/.../ports/2.1`. The controller component makes the identity
    robust against USB root hub renumbering while retaining physical location.
    Synthetic test trees can supply `MESH_RADIO_PORT_PATH` in `uevent`.
    """
    try:
        resolved = os.path.realpath(entry)
    except OSError:
        resolved = ""
    marker = "/devices/"
    if marker in resolved:
        remainder = resolved.split(marker, 1)[1].split("/")
        for index, component in enumerate(remainder):
            if component.startswith("usb") and component[3:].isdigit() and index + 1 < len(remainder):
                leaf = remainder[index + 1]
                match = TOPOLOGY_RE.fullmatch(leaf)
                if match:
                    ports = leaf.split("-", 1)[1]
                    controller = "/".join(remainder[:index])
                    return f"{controller}/ports/{ports}" if controller else f"ports/{ports}"
    uevent = _read_text(entry / "uevent") or ""
    for line in uevent.splitlines():
        if line.startswith("MESH_RADIO_PORT_PATH="):
            return line.split("=", 1)[1] or None
    return None


def enumerate_devices(sysfs_root: Path = SYS_USB_ROOT) -> list[UsbDevice]:
    """List USB devices with descriptor and volatile runtime data."""
    try:
        entries = list(sysfs_root.iterdir())
    except OSError:
        return []
    result: list[UsbDevice] = []
    for entry in entries:
        if not TOPOLOGY_RE.fullmatch(entry.name):
            continue
        vid = _read_int(entry / "idVendor", 16)
        pid = _read_int(entry / "idProduct", 16)
        bus = _read_int(entry / "busnum")
        address = _read_int(entry / "devnum")
        if None in (vid, pid, bus, address):
            continue
        result.append(
            UsbDevice(
                vid=vid,
                pid=pid,
                bus=bus,
                address=address,
                path=entry.name,
                port_path=_stable_port_path(entry),
                serial=_read_text(entry / "serial"),
                manufacturer=_read_text(entry / "manufacturer"),
                product=_read_text(entry / "product"),
                driver=_driver(entry),
            )
        )
    return sorted(result, key=lambda item: (item.bus, item.path, item.address))


def ch341_devices(sysfs_root: Path = SYS_USB_ROOT) -> list[UsbDevice]:
    return [item for item in enumerate_devices(sysfs_root) if (item.vid, item.pid) == (0x1A86, 0x5512)]


def parse_selector(value: str, devices: list[UsbDevice]) -> UsbDevice:
    """Resolve a user-provided, non-volatile selector exactly once."""
    try:
        kind, expected = value.split(":", 1)
    except ValueError as error:
        raise ManagerError("Device selector must be serial:<value>, port:<value>, or path:<value>") from error
    attribute = {"serial": "serial", "port": "port_path", "path": "path"}.get(kind)
    if attribute is None or not expected:
        raise ManagerError("Device selector must be serial:<value>, port:<value>, or path:<value>")
    matches = [item for item in devices if getattr(item, attribute) == expected]
    if not matches:
        raise ManagerError(f"No connected radio matches {value!r}")
    if len(matches) != 1:
        raise ManagerError(f"Selector {value!r} is ambiguous; use a USB serial or physical port selector")
    return matches[0]
