#!/bin/sh
# Development/local installer. Production installs use the signed Debian package.
set -eu
umask 077

project_dir=$(
    CDPATH=''
    cd -- "$(dirname -- "$0")"
    pwd
)
manager_root=/opt/mesh-radio-manager
config_dir=/etc/mesh-radio-manager
install_meshtastic=0
enable_web=0
channel=beta

usage() {
    echo "Usage: sudo ./install.sh [--install-meshtastic] [--channel alpha|beta] [--web]" >&2
    echo "Run this only from a checked-out source tree or verified release bundle." >&2
}

if [ ! -f "$project_dir/pyproject.toml" ] || [ ! -f "$project_dir/src/mesh_radio_manager/__init__.py" ]; then
    echo "Refusing to bootstrap from a pipe or an incomplete directory." >&2
    echo "Download and verify a versioned release bundle, then run its extracted install.sh." >&2
    exit 2
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-meshtastic) install_meshtastic=1 ;;
        --web) enable_web=1 ;;
        --channel)
            shift
            [ "$#" -gt 0 ] || { usage; exit 2; }
            channel=$1
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "Run this installer as root." >&2; exit 1; }
if [ ! -d /root/openhop-repeater ] || [ ! -f /etc/openhop_repeater/config.yaml ]; then
    echo "Official openHop LXC installation not detected. Install openHop from openhop-dev/openhop_repeater first." >&2
    exit 1
fi
[ "$channel" = alpha ] || [ "$channel" = beta ] || { echo "Channel must be alpha or beta." >&2; exit 2; }
command -v flock >/dev/null 2>&1 || { echo "flock is required for safe staged installation." >&2; exit 1; }

runtime_dir=/run/mesh-radio-manager
install -d -m 0750 "$runtime_dir"
exec 9>"$runtime_dir/package-lifecycle.lock"
flock -n 9 || { echo "Another Mesh Radio Manager install or update is already running." >&2; exit 1; }

# The local/developer path deliberately avoids PyPI resolution. Its sole Python
# dependency is installed by Debian and exposed to this isolated venv.
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-yaml

release_version=$(awk -F'"' '/^version[[:space:]]*=/ {print $2; exit}' "$project_dir/pyproject.toml")
case "$release_version" in
    ''|*[!0-9A-Za-z.+~-]*)
        echo "Cannot determine a safe project version from pyproject.toml." >&2
        exit 1
        ;;
esac

install -d -m 0750 "$manager_root" "$manager_root/releases" "$config_dir" /var/lib/mesh-radio-manager /var/log/mesh-radio-manager
stage_dir=$(mktemp -d "$manager_root/releases/.stage.XXXXXX")
cleanup_stage() {
    [ -z "${stage_dir:-}" ] || rm -rf "$stage_dir"
}
trap cleanup_stage EXIT HUP INT TERM

cp -a "$project_dir/." "$stage_dir/source/"
python3 -m venv --system-site-packages "$stage_dir/venv"
"$stage_dir/venv/bin/pip" install --no-deps --no-compile "$stage_dir/source"
"$stage_dir/venv/bin/mesh-radio" --version >/dev/null

release_id="${release_version}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
release_dir="$manager_root/releases/$release_id"
mv "$stage_dir" "$release_dir"
stage_dir=""

replace_link() {
    link_target=$1
    link_path=$2
    temporary_link="${link_path}.new.$$"
    rm -f "$temporary_link"
    ln -s "$link_target" "$temporary_link"
    mv -f "$temporary_link" "$link_path"
}

current_link="$manager_root/current"
replace_link "releases/$release_id" "$current_link"

# Existing source/venv directories are intentionally retained during the first
# migration. A running process can safely finish against the old generation;
# all new executions resolve through the atomically swapped current link.
manager_cli="$manager_root/current/venv/bin/mesh-radio"
compat_launcher=/usr/local/bin/mesh-radio
if [ -e "$compat_launcher" ] || [ -L "$compat_launcher" ]; then
    compat_target=$(readlink -f "$compat_launcher" 2>/dev/null || true)
    case "$compat_target" in
        "$manager_root"/venv/bin/mesh-radio|"$manager_root"/current/venv/bin/mesh-radio|"$manager_root"/releases/*/venv/bin/mesh-radio)
            ;;
        *)
            echo "Refusing to replace existing non-manager launcher: $compat_launcher" >&2
            exit 1
            ;;
    esac
fi
replace_link "$manager_cli" "$compat_launcher"
if ! "$compat_launcher" --version >/dev/null; then
    echo "Mesh Radio Manager CLI launcher validation failed." >&2
    exit 1
fi

# Some pct-enter shells omit /usr/local/bin. Keep this compatibility link
# separate and refuse to overwrite an unrelated command.
legacy_launcher=/usr/bin/mesh-radio
if [ -e "$legacy_launcher" ] || [ -L "$legacy_launcher" ]; then
    legacy_target=$(readlink -f "$legacy_launcher" 2>/dev/null || true)
    [ "$legacy_target" = "$manager_cli" ] || {
        echo "Refusing to replace existing non-manager launcher: $legacy_launcher" >&2
        exit 1
    }
else
    ln -s /usr/local/bin/mesh-radio "$legacy_launcher"
fi

replace_link "$manager_root/current/source/update.sh" "$manager_root/update.sh"
replace_link "$manager_root/current/source/manager-update.sh" "$manager_root/manager-update.sh"
install -m 0755 "$manager_root/current/source/scripts/mesh-radio-menu" /usr/local/bin/mesh-radio-menu
install -m 0644 "$manager_root/current/source/scripts/mesh-radio-manager-profile.sh" /etc/profile.d/mesh-radio-manager.sh
if [ ! -f "$config_dir/config.yaml" ]; then
    install -m 0640 "$manager_root/current/source/config/config.example.yaml" "$config_dir/config.yaml"
fi
if getent group repeater >/dev/null 2>&1; then
    chown root:repeater "$config_dir" "$config_dir/config.yaml"
    chmod 0750 "$config_dir"
    chmod 0640 "$config_dir/config.yaml"
fi

# Recover dashboard changes that an older manager release placed in /run
# before installing the persistence-safe openHop drop-in.
"$manager_cli" internal migrate-openhop-config

if [ "$enable_web" -eq 1 ]; then
    "$manager_cli" install-integration --web
else
    "$manager_cli" install-integration
fi
if [ "$install_meshtastic" -eq 1 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg
    "$manager_cli" meshtastic install --channel "$channel"
fi

echo "Mesh Radio Manager installed as staged generation $release_id. Assign radios with: mesh-radio radios"
