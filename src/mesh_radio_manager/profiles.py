"""Verified meshtasticd CH341/SX1262 hardware profiles."""

from __future__ import annotations

import copy
from typing import Any, Mapping

from .errors import ManagerError
from .usb import UsbDevice

# These field names are from Meshtastic's current Portduino configuration and
# the upstream lora-usb-meshtoad-e22.yaml profile. Do not add RF region or
# power here: those are node settings managed by Meshtastic itself.
MESHTASTIC_PROFILES: dict[str, dict[str, Any]] = {
    "pinedio": {
        "name": "PineDio USB SX1262",
        "source": "Meshtastic lora-pinedio-usb-sx1262.yaml",
        "lora": {"Module": "sx1262", "CS": 0, "IRQ": 10, "spidev": "ch341"},
    },
    "meshtadpole": {
        "name": "MeshTadpole USB SX1262",
        "source": "Meshtastic lora-usb-meshtoad-e22.yaml",
        "lora": {
            "Module": "sx1262",
            "CS": 0,
            "IRQ": 6,
            "Reset": 2,
            "Busy": 4,
            "RXen": 1,
            "DIO2_AS_RF_SWITCH": True,
            "DIO3_TCXO_VOLTAGE": True,
            "spidev": "ch341",
        },
    },
    "generic-ch341-sx1262": {
        "name": "Generic CH341/SX1262 (requires verified pins)",
        "source": None,
        "lora": {},
    },
}


def _merge(destination: dict[str, Any], source: Mapping[str, Any]) -> dict[str, Any]:
    for key, value in source.items():
        if isinstance(value, Mapping) and isinstance(destination.get(key), dict):
            _merge(destination[key], value)
        else:
            destination[key] = copy.deepcopy(value)
    return destination


def effective_meshtastic_config(assignment: Mapping[str, Any], device: UsbDevice, advanced: Mapping[str, Any] | None = None) -> dict[str, Any]:
    profile_name = str(assignment.get("profile") or "")
    profile = MESHTASTIC_PROFILES.get(profile_name)
    if profile is None:
        raise ManagerError(f"Unknown Meshtastic hardware profile {profile_name!r}")
    lora = copy.deepcopy(profile["lora"])
    custom = assignment.get("lora")
    if custom is not None:
        if not isinstance(custom, Mapping):
            raise ManagerError("Custom Lora profile fields must be a YAML mapping")
        _merge(lora, custom)
    required = ("Module", "CS", "IRQ", "spidev")
    missing = [field for field in required if field not in lora]
    if missing:
        raise ManagerError(
            "Generic CH341/SX1262 configuration needs verified explicit pin mapping; missing "
            + ", ".join(missing)
        )
    if lora["Module"] != "sx1262" or lora["spidev"] != "ch341":
        raise ManagerError("Only a verified CH341-backed SX1262 profile is accepted")
    lora["USB_VID"] = device.vid
    lora["USB_PID"] = device.pid
    if device.serial:
        # Upstream Meshtastic's exact selector spelling.
        lora["USB_Serialnum"] = device.serial
    if advanced:
        if not isinstance(advanced, Mapping):
            raise ManagerError("Meshtastic advanced configuration must be a YAML mapping")
        protected = {"Lora", "Webserver"}.intersection(advanced)
        if protected:
            raise ManagerError(
                "Advanced Meshtastic configuration cannot override protected "
                + ", ".join(sorted(protected))
                + " settings"
            )
        result = _merge({}, advanced)
    else:
        result = {}
    result["Lora"] = lora
    return result
