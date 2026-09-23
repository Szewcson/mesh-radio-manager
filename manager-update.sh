#!/bin/sh
# Update only the signed Debian package. Source-tree updates are deliberately
# refused so a mutable branch can never become the production trust boundary.
set -eu
umask 077

package_name=mesh-radio-manager

[ "$(id -u)" -eq 0 ] || { echo "Run manager update as root." >&2; exit 1; }
command -v flock >/dev/null 2>&1 || {
    echo "flock is required to prevent concurrent manager updates." >&2
    exit 1
}
command -v dpkg-query >/dev/null 2>&1 || {
    echo "A Debian package installation is required for manager updates." >&2
    exit 1
}
dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null | grep -qx installed || {
    echo "Mesh Radio Manager is not installed as a Debian package." >&2
    echo "Install a verified release package before using self-update." >&2
    exit 1
}

runtime_dir=/run/mesh-radio-manager
mkdir -p "$runtime_dir"
chmod 0750 "$runtime_dir"
exec 3>"$runtime_dir/package-lifecycle.lock"
flock -n 3 || {
    echo "Another Mesh Radio Manager install or update is already running." >&2
    exit 1
}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade --yes "$package_name"
