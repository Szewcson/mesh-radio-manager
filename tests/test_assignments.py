from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import os
import stat

from mesh_radio_manager.assignments import identity_from_device, resolve, save, validate
from mesh_radio_manager.errors import ManagerError
from mesh_radio_manager.profiles import effective_meshtastic_config
from mesh_radio_manager.usb import UsbDevice


def radio(*, serial: str | None = None, port: str | None = None, bus: int = 4, address: int = 2, path: str = "4-1") -> UsbDevice:
    return UsbDevice(0x1A86, 0x5512, bus, address, path, port, serial, "WCH", "CH341")


class AssignmentTests(unittest.TestCase):
    def test_atomic_save_preserves_existing_permissions_and_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            path.write_text("version: 1\nassignments: {}\n", encoding="utf-8")
            os.chmod(path, 0o640)
            before = path.stat()

            save({"version": 1, "assignments": {}}, path)

            after = path.stat()
            self.assertEqual(stat.S_IMODE(after.st_mode), stat.S_IMODE(before.st_mode))
            self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))

    def test_two_identical_devices_can_use_unique_serials(self) -> None:
        first = radio(serial="PINE", path="4-1")
        second = radio(serial="TADPOLE", address=3, path="4-2")
        self.assertIs(resolve({"vid": "1a86", "pid": "5512", "serial": "TADPOLE"}, [first, second]), second)

    def test_no_serial_uses_stable_controller_port(self) -> None:
        first = radio(port="pci0000:00/ports/1", path="4-1")
        second = radio(port="pci0000:00/ports/2", address=3, path="4-2")
        identity = identity_from_device(second, [first, second])
        self.assertEqual(identity["port_path"], "pci0000:00/ports/2")
        self.assertIs(resolve(identity, [first, second]), second)

    def test_bus_address_change_does_not_change_topology_assignment(self) -> None:
        before = radio(port="pci0000:00/ports/2", bus=4, address=3, path="4-2")
        after = radio(port="pci0000:00/ports/2", bus=8, address=7, path="8-2")
        identity = identity_from_device(before, [before])
        self.assertEqual((resolve(identity, [after]).bus, resolve(identity, [after]).address), (8, 7))

    def test_two_unidentifiable_radios_are_rejected(self) -> None:
        first = radio(path="4-1")
        second = radio(address=3, path="4-2")
        with self.assertRaisesRegex(ManagerError, "indistinguishable"):
            identity_from_device(first, [first, second])

    def test_same_device_conflict_is_rejected_before_start(self) -> None:
        data = {
            "version": 1,
            "assignments": {
                "openhop": {"identity": {"vid": "1a86", "pid": "5512", "serial": "same"}, "profile": "pinedio"},
                "meshtastic": {"identity": {"vid": "1a86", "pid": "5512", "serial": "same"}, "profile": "meshtadpole"},
            },
        }
        with self.assertRaisesRegex(ManagerError, "both"):
            validate(data, [radio(serial="same")])

    def test_runtime_conflict_is_rejected_when_two_identity_forms_resolve_one_radio(self) -> None:
        device = radio(serial="same", port="pci0000:00/ports/2")
        data = {
            "version": 1,
            "assignments": {
                "openhop": {"identity": {"vid": "1a86", "pid": "5512", "serial": "same"}, "profile": "pinedio"},
                "meshtastic": {
                    "identity": {"vid": "1a86", "pid": "5512", "port_path": "pci0000:00/ports/2"},
                    "profile": "meshtadpole",
                },
            },
        }
        with self.assertRaisesRegex(ManagerError, "resolves to both"):
            validate(data, [device])

    def test_missing_assigned_device_is_rejected(self) -> None:
        with self.assertRaisesRegex(ManagerError, "not present"):
            resolve({"vid": "1a86", "pid": "5512", "serial": "gone"}, [])

    def test_generic_profile_requires_verified_pins(self) -> None:
        with self.assertRaisesRegex(ManagerError, "verified explicit pin mapping"):
            effective_meshtastic_config({"profile": "generic-ch341-sx1262"}, radio(serial="one"))

    def test_meshtadpole_uses_verified_upstream_field_names(self) -> None:
        config = effective_meshtastic_config({"profile": "meshtadpole"}, radio(serial="12345678"))
        self.assertEqual(config["Lora"]["USB_Serialnum"], "12345678")
        self.assertEqual(config["Lora"]["IRQ"], 6)
        self.assertTrue(config["Lora"]["DIO2_AS_RF_SWITCH"])


if __name__ == "__main__":
    unittest.main()
