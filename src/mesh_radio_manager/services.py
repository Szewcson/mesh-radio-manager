"""Small, testable systemd adapter. No service state is cached."""

from __future__ import annotations

import subprocess
from typing import Sequence

from .errors import ManagerError


def _run(arguments: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(arguments, text=True, capture_output=True, check=check, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ManagerError(f"Cannot run {' '.join(arguments)}: {error}") from error


def state(unit: str) -> dict[str, str]:
    result = _run(["systemctl", "show", unit, "--property=LoadState,ActiveState,SubState", "--value"], check=False)
    values = (result.stdout.splitlines() + ["unknown", "unknown", "unknown"])[:3]
    return {"load": values[0], "active": values[1], "sub": values[2]}


def action(unit: str, verb: str) -> None:
    if verb not in {"start", "stop", "restart", "enable", "disable"}:
        raise ManagerError(f"Unsupported service action {verb!r}")
    result = _run(["systemctl", verb, unit], check=False)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise ManagerError(f"{verb} {unit} failed: {detail}")


def logs(unit: str, lines: int = 100) -> str:
    if not 1 <= lines <= 1000:
        raise ManagerError("Log line count must be between 1 and 1000")
    return _run(["journalctl", "--no-pager", "-u", unit, "-n", str(lines)], check=False).stdout


def listening_ports() -> str:
    return _run(["ss", "-ltnp"], check=False).stdout
