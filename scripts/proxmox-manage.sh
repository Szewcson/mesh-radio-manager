#!/usr/bin/env bash
# Proxmox-host control panel for an installed Mesh Radio Manager LXC.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run this from the Proxmox host as root." >&2; exit 1; }
command -v pct >/dev/null || { echo "Proxmox pct command not found." >&2; exit 1; }

usage() {
  echo "Usage: mesh-radio-pve [--ctid CTID]"
}

ctid=""
if (($#)); then
  [[ $# -eq 2 && "$1" == "--ctid" && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
  ctid="$2"
fi
if [[ -z "$ctid" ]]; then
  pct list
  read -r -p "Mesh Radio Manager CTID: " ctid
fi
[[ "$ctid" =~ ^[0-9]+$ ]] && pct status "$ctid" >/dev/null 2>&1 || {
  echo "Invalid CTID: $ctid" >&2; exit 2;
}

run_in_lxc() {
  pct exec "$ctid" -- "$@"
}

while :; do
  clear
  echo "╔══════════════════════════════════════════════╗"
  echo "║     Mesh Radio Manager — Proxmox Control     ║"
  echo "╚══════════════════════════════════════════════╝"
  echo "  CTID: $ctid ($(pct status "$ctid" | awk '{print $2}'))"
  echo "  1) Status"
  echo "  2) Radios and assignments"
  echo "  3) Verify USB ownership"
  echo "  4) Diagnostics"
  echo "  5) Logs"
  echo "  6) Restart radio services"
  echo "  7) Update everything"
  echo "  8) Enter LXC shell"
  echo "  0) Exit"
  read -r -p " Select: " choice
  case "$choice" in
    1) run_in_lxc mesh-radio status ;;
    2) run_in_lxc mesh-radio radios ;;
    3) run_in_lxc mesh-radio verify ;;
    4) run_in_lxc mesh-radio diagnose ;;
    5)
      read -r -p " Service (openhop/meshtastic): " service
      case "$service" in openhop|meshtastic) run_in_lxc mesh-radio logs "$service" ;; *) echo "Unknown service" ;; esac
      ;;
    6)
      run_in_lxc systemctl restart meshtasticd
      run_in_lxc systemctl restart openhop-repeater
      ;;
    7)
      read -r -p "Run official openHop + manager + meshtasticd update? [y/N]: " answer
      [[ "$answer" =~ ^[Yy]$ ]] && run_in_lxc mesh-radio update
      ;;
    8) pct enter "$ctid" ;;
    0) exit 0 ;;
    *) echo "Unknown selection" ;;
  esac
  read -r -p "Press Enter to continue..." _
done
