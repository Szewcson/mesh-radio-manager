#!/bin/sh
# Update Mesh Radio Manager and meshtasticd together. This deliberately never
# invokes the official openHop updater.
set -eu

manager_root=/opt/mesh-radio-manager
source_dir=$manager_root/source
openhop_updater=/root/openhop-repeater/manage.sh

[ "$(id -u)" -eq 0 ] || { echo "Run update as root." >&2; exit 1; }
[ "$#" -eq 0 ] || { echo "Usage: sudo mesh-radio update" >&2; exit 2; }
[ -x "$openhop_updater" ] || {
    echo "Official openHop updater not found at $openhop_updater. Install openHop first; it was not modified." >&2
    exit 1
}
[ -d "$source_dir/.git" ] || {
    echo "This installation came from a release archive, not a Git checkout. Install a newer release using its install.sh." >&2
    exit 1
}

echo "=== Updating openHop with its official upstream updater ==="
"$openhop_updater" upgrade

echo "=== Updating Mesh Radio Manager ==="
git -C "$source_dir" pull --ff-only
"$source_dir/install.sh"

echo "=== Updating meshtasticd ==="
# Show the exact package state before upgrading. `upgrade --yes` makes a
# timestamped backup of /etc/meshtasticd/config.yaml before apt runs.
/usr/local/bin/mesh-radio meshtastic status
exec /usr/local/bin/mesh-radio meshtastic upgrade --yes
