#!/bin/sh
# Update Mesh Radio Manager and meshtasticd together. This deliberately never
# invokes the official openHop updater.
set -eu

manager_root=/opt/mesh-radio-manager
source_dir=$manager_root/source
openhop_updater=/root/openhop-repeater/manage.sh
manager_repository=https://github.com/Szewcson/mesh-radio-manager.git

[ "$(id -u)" -eq 0 ] || { echo "Run update as root." >&2; exit 1; }
[ "$#" -eq 0 ] || { echo "Usage: sudo mesh-radio update" >&2; exit 2; }
[ -x "$openhop_updater" ] || {
    echo "Official openHop updater not found at $openhop_updater. Install openHop first; it was not modified." >&2
    exit 1
}
echo "=== Updating openHop with its official upstream updater ==="
"$openhop_updater" upgrade

echo "=== Updating Mesh Radio Manager ==="
if [ -d "$source_dir/.git" ]; then
    git -C "$source_dir" pull --ff-only
    update_source=$source_dir
else
    # Curl/release installations intentionally contain no Git metadata. Fetch
    # the standalone manager source only; the official openHop source remains
    # outside this project and was updated by its own command above.
    update_checkout=$(mktemp -d /tmp/mesh-radio-manager-update.XXXXXX)
    trap 'rm -rf "$update_checkout"' EXIT HUP INT TERM
    git clone --depth 1 "$manager_repository" "$update_checkout/source"
    update_source=$update_checkout/source
fi
"$update_source/install.sh"

echo "=== Updating meshtasticd ==="
# Show the exact package state before upgrading. `upgrade --yes` makes a
# timestamped backup of /etc/meshtasticd/config.yaml before apt runs.
/usr/local/bin/mesh-radio meshtastic status
exec /usr/local/bin/mesh-radio meshtastic upgrade --yes
