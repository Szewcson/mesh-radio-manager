"""Administrator CLI. It is complete without the optional web dashboard."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
from typing import Any

import yaml

from . import __version__
from .assignments import assign, configuration_lock, load, save, set_meshtastic_channel, validate
from .diagnostics import report
from .errors import ManagerError
from .integration import install as install_integration
from .integration import uninstall as uninstall_integration
from .meshtastic import (
    MESHTASTIC_CONFIG,
    MESHTASTIC_UNIT,
    backup_config,
    install_package,
    package_versions,
    prepare_runtime_config as prepare_meshtastic,
    restore_config,
    restore_web_ui,
    run_daemon,
    set_web_ui,
    upgrade,
    web_ui_status,
)
from .openhop import (
    OPENHOP_UNIT,
    installed as openhop_installed,
    metadata as openhop_metadata,
    migrate_newer_runtime_config,
    prepare_persistent_config as prepare_openhop,
)
from .profiles import MESHTASTIC_PROFILES
from .services import action, listening_ports, logs, state
from .usb import enumerate_devices, parse_selector
from .web import serve


PACKAGE_CONTROL_DIR = Path("/usr/lib/mesh-radio-manager")
LEGACY_CONTROL_DIR = Path("/opt/mesh-radio-manager")


def _control_script(name: str) -> str:
    """Prefer package-owned controls; retain legacy staging during migration."""
    packaged = PACKAGE_CONTROL_DIR / name
    if packaged.is_file():
        return str(packaged)
    return str(LEGACY_CONTROL_DIR / name)


def _emit(value: Any, as_json: bool) -> None:
    if as_json or isinstance(value, (dict, list)):
        print(json.dumps(value, indent=2, sort_keys=False, default=str))
    elif value is not None:
        print(value)


def _require_stopped() -> None:
    running = [unit for unit in (OPENHOP_UNIT, MESHTASTIC_UNIT) if state(unit)["active"] in {"active", "activating", "reloading"}]
    if running:
        raise ManagerError(
            "Stop " + ", ".join(running) + " before changing assignments; this prevents live radio hand-off"
        )


def _load_lora(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    try:
        data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ManagerError(f"Cannot load verified Lora mapping: {error}") from error
    if not isinstance(data, dict):
        raise ManagerError("Verified Lora mapping must be a YAML mapping")
    return data


def _status() -> dict[str, Any]:
    configuration = load()
    return {
        "manager_version": __version__,
        "openhop": {**openhop_metadata(), "service": state(OPENHOP_UNIT)},
        "meshtasticd": {"service": state(MESHTASTIC_UNIT), "packages": package_versions()},
        "meshtastic_web_ui": web_ui_status(configuration, listening_ports()),
        "assignments": configuration.get("assignments", {}),
    }


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="mesh-radio", description="Independent USB radio manager for openHop and meshtasticd")
    root.add_argument("--json", action="store_true", help="print machine-readable JSON")
    root.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("radios")
    assign_parser = commands.add_parser("assign")
    assign_parser.add_argument("role", choices=("openhop", "meshtastic"))
    assign_parser.add_argument("device", help="serial:<value>, port:<controller/ports>, or path:<runtime-topology>")
    assign_parser.add_argument("--profile", required=True, choices=("pinedio", "meshtadpole", "generic-ch341-sx1262"))
    assign_parser.add_argument("--verified-lora", help="YAML pin mapping for generic-ch341-sx1262 only")
    commands.add_parser("verify")
    commands.add_parser("diagnose")
    commands.add_parser("update", help="update openHop, the signed manager package, and meshtasticd")
    manager = commands.add_parser("manager", help="manage Mesh Radio Manager itself")
    manager.add_subparsers(dest="manager_command", required=True).add_parser(
        "update", help="update only Mesh Radio Manager through its signed Debian package"
    )
    commands.add_parser("install-integration").add_argument("--web", action="store_true")

    openhop = commands.add_parser("openhop").add_subparsers(dest="openhop_command", required=True)
    for command in ("status", "start", "stop", "restart"):
        openhop.add_parser(command)

    meshtastic = commands.add_parser("meshtastic").add_subparsers(dest="meshtastic_command", required=True)
    install = meshtastic.add_parser("install")
    install.add_argument("--channel", default="beta", choices=("alpha", "beta"))
    for command in ("status", "start", "stop", "restart", "configure", "backup"):
        configure = meshtastic.add_parser(command)
        if command == "configure":
            configure.add_argument(
                "--advanced-file",
                help="verified non-Lora meshtasticd YAML to store in manager configuration",
            )
    restore = meshtastic.add_parser("restore")
    restore.add_argument("backup")
    upgrade_parser = meshtastic.add_parser("upgrade")
    upgrade_parser.add_argument("--yes", action="store_true")
    meshtastic_web = meshtastic.add_parser("web").add_subparsers(dest="meshtastic_web_command", required=True)
    meshtastic_web.add_parser("status")
    web_enable = meshtastic_web.add_parser("enable")
    web_enable.add_argument("--port", type=int, help="HTTPS port; defaults to 9443")
    meshtastic_web.add_parser("disable")

    log_parser = commands.add_parser("logs")
    log_parser.add_argument("service", choices=("openhop", "meshtastic"))
    log_parser.add_argument("--lines", type=int, default=100)
    web = commands.add_parser("web").add_subparsers(dest="web_command", required=True)
    web.add_parser("serve")
    web.add_parser("enable")
    internal = commands.add_parser("internal").add_subparsers(dest="internal_command", required=True)
    internal.add_parser("prepare-openhop")
    internal.add_parser("migrate-openhop-config")
    internal.add_parser("uninstall-integration")
    internal.add_parser("run-meshtastic")
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "status":
            value: Any = _status()
        elif args.command == "radios":
            assignments = load().get("assignments", {})
            resolved = validate(load(), enumerate_devices(), require_present=False)
            del resolved
            value = []
            for device in enumerate_devices():
                role = None
                for candidate, assignment in assignments.items():
                    identity = assignment.get("identity", {}) if isinstance(assignment, dict) else {}
                    if identity.get("serial") == device.serial or identity.get("port_path") == device.port_path:
                        role = candidate
                value.append(device.public_dict(role))
        elif args.command == "assign":
            _require_stopped()
            devices = enumerate_devices()
            device = parse_selector(args.device, devices)
            if args.role == "openhop" and args.profile not in {"pinedio", "generic-ch341-sx1262"}:
                raise ManagerError("MeshTadpole is not an openHop preset; use official openHop hardware configuration")
            value = assign(args.role, device, args.profile, devices, lora=_load_lora(args.verified_lora))
        elif args.command == "verify":
            if not openhop_installed():
                raise ManagerError("Official openHop installation is missing; this manager will not recreate it")
            with configuration_lock():
                value = {
                    "openhop": openhop_metadata(),
                    "resolved_assignments": {role: device.public_dict() for role, device in validate(load(), enumerate_devices()).items()},
                    "profiles": MESHTASTIC_PROFILES,
                }
        elif args.command == "diagnose":
            value = report()
        elif args.command == "manager":
            result = subprocess.run([_control_script("manager-update.sh")], text=True)
            if result.returncode:
                raise ManagerError("Mesh Radio Manager self-update failed")
            value = {"manager_updated": True}
        elif args.command == "install-integration":
            install_integration(enable_web=args.web)
            value = {"installed": True, "web_enabled": args.web}
        elif args.command == "openhop":
            if args.openhop_command == "status":
                value = {**openhop_metadata(), "service": state(OPENHOP_UNIT)}
            else:
                action(OPENHOP_UNIT, args.openhop_command)
                value = state(OPENHOP_UNIT)
        elif args.command == "meshtastic":
            if args.meshtastic_command == "install":
                # The package may enable a systemd service. Install the
                # guarded unit before apt can ever expose it at boot.
                install_integration(enable_web=False)
                value = install_package(args.channel)
                set_meshtastic_channel(args.channel)
            elif args.meshtastic_command == "status":
                value = {"service": state(MESHTASTIC_UNIT), "packages": package_versions()}
            elif args.meshtastic_command == "configure":
                if args.advanced_file:
                    try:
                        advanced = yaml.safe_load(Path(args.advanced_file).read_text(encoding="utf-8")) or {}
                    except (OSError, yaml.YAMLError) as error:
                        raise ManagerError(f"Cannot load advanced Meshtastic YAML: {error}") from error
                    protected = {"Lora", "Webserver"}.intersection(advanced) if isinstance(advanced, dict) else set()
                    if not isinstance(advanced, dict) or protected:
                        raise ManagerError(
                            "Advanced Meshtastic YAML must be a mapping and cannot contain protected "
                            "Lora or Webserver settings"
                        )
                    with configuration_lock():
                        data = load()
                        data.setdefault("meshtastic", {})["advanced"] = advanced
                        save(data)
                    value = {"saved_advanced_config": True}
                else:
                    value = {"effective_config": str(prepare_meshtastic())}
            elif args.meshtastic_command == "backup":
                backup = backup_config()
                value = {"backup": str(backup) if backup else None}
            elif args.meshtastic_command == "restore":
                restore_config(Path(args.backup))
                value = {"restored": args.backup, "destination": str(MESHTASTIC_CONFIG)}
            elif args.meshtastic_command == "upgrade":
                value = {"backup": str(upgrade(assume_yes=args.yes)) if args.yes else package_versions()}
                if not args.yes:
                    raise ManagerError(
                        f"meshtasticd installed={value['installed']}, candidate={value['candidate']}; rerun with --yes"
                    )
            elif args.meshtastic_command == "web":
                if args.meshtastic_web_command == "status":
                    value = web_ui_status(load(), listening_ports())
                else:
                    enabled = args.meshtastic_web_command == "enable"
                    port = args.port if enabled else None
                    previous, _ = set_web_ui(enabled, port=port, listening=listening_ports())
                    try:
                        action(MESHTASTIC_UNIT, "restart")
                    except ManagerError as error:
                        restore_web_ui(previous)
                        try:
                            action(MESHTASTIC_UNIT, "restart")
                        except ManagerError:
                            pass
                        raise ManagerError(f"Meshtastic web UI change was reverted: {error}") from error
                    value = web_ui_status(load(), listening_ports())
            else:
                action(MESHTASTIC_UNIT, args.meshtastic_command)
                value = state(MESHTASTIC_UNIT)
        elif args.command == "logs":
            value = logs(OPENHOP_UNIT if args.service == "openhop" else MESHTASTIC_UNIT, args.lines)
        elif args.command == "web":
            if args.web_command == "enable":
                action("mesh-radio-manager-web.service", "enable")
                action("mesh-radio-manager-web.service", "start")
                value = state("mesh-radio-manager-web.service")
            else:
                serve()
                return 0
        elif args.command == "internal":
            if args.internal_command == "prepare-openhop":
                value = {"persistent_config": str(prepare_openhop())}
            elif args.internal_command == "migrate-openhop-config":
                value = {"migrated_legacy_runtime_config": migrate_newer_runtime_config()}
            elif args.internal_command == "uninstall-integration":
                uninstall_integration()
                value = {"uninstalled": True}
            else:
                return run_daemon()
        elif args.command == "update":
            result = subprocess.run([_control_script("update.sh")], text=True)
            if result.returncode:
                raise ManagerError("Mesh Radio Manager update failed")
            value = {"manager_updated": True, "meshtastic_updated": True}
        else:
            raise ManagerError("Unhandled command")
    except ManagerError as error:
        print(f"mesh-radio: {error}", file=sys.stderr)
        return 2
    _emit(value, args.json)
    return 0
