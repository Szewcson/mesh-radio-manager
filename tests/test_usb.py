from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from mesh_radio_manager.usb import ch341_devices, enumerate_devices, parse_selector


class UsbDiscoveryTests(unittest.TestCase):
    def _device(self, root: Path, name: str, *, serial: str | None, port: str, bus: int, address: int) -> None:
        entry = root / name
        entry.mkdir()
        (entry / "idVendor").write_text("1a86\n", encoding="utf-8")
        (entry / "idProduct").write_text("5512\n", encoding="utf-8")
        (entry / "busnum").write_text(f"{bus}\n", encoding="utf-8")
        (entry / "devnum").write_text(f"{address}\n", encoding="utf-8")
        (entry / "manufacturer").write_text("WCH\n", encoding="utf-8")
        (entry / "product").write_text("USB UART\n", encoding="utf-8")
        lines = [f"MESH_RADIO_PORT_PATH={port}"]
        if serial:
            (entry / "serial").write_text(serial + "\n", encoding="utf-8")
        (entry / "uevent").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_mocked_sysfs_inventory_contains_stable_and_runtime_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._device(root, "4-1", serial="PINE", port="pci0000:00/ports/1", bus=4, address=2)
            self._device(root, "4-2", serial=None, port="pci0000:00/ports/2", bus=4, address=3)
            devices = ch341_devices(root)
            self.assertEqual(len(devices), 2)
            self.assertEqual(devices[0].serial, "PINE")
            self.assertEqual(devices[1].port_path, "pci0000:00/ports/2")
            self.assertEqual(parse_selector("port:pci0000:00/ports/2", devices).address, 3)

    def test_non_usb_sysfs_entries_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "usb1").mkdir()
            self.assertEqual(enumerate_devices(Path(directory)), [])


if __name__ == "__main__":
    unittest.main()
