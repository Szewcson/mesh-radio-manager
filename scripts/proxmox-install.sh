#!/usr/bin/env bash
# Mesh Radio Manager host installer for Proxmox VE.
#
# Styled after Proxmox VE Helper-Scripts conventions, but maintained here.
# openHop is never vendored: its official host installer remains external.
set -Eeuo pipefail

OPENHOP_INSTALLER="https://raw.githubusercontent.com/openhop-dev/openhop_repeater/main/scripts/proxmox-install.sh"
DEFAULT_CHANNEL="alpha"
MANAGER_TAG="mesh-radio-manager"
OPENHOP_DEFAULT_HOSTNAME_LINE='CT_HOSTNAME="openhop-repeater"'
MANAGER_DEFAULT_HOSTNAME_LINE='CT_HOSTNAME="mesh-radio-manager"'
script_dir=$(
  CDPATH=''
  cd -- "$(dirname -- "$0")"
  pwd
)

RD="\033[01;31m"
GN="\033[1;92m"
YW="\033[33m"
BL="\033[36m"
BLD="\033[1m"
CL="\033[m"

msg_info() { echo -e " ${BL}ℹ${CL} $*"; }
msg_ok() { echo -e " ${GN}✓${CL} $*"; }
msg_warn() { echo -e " ${YW}⚠${CL} $*"; }
msg_error() { echo -e " ${RD}✗${CL} $*" >&2; }

usage() {
  cat <<'EOF'
Usage: proxmox-install.sh [--ctid CTID] --manager-package PATH [options]

Without --ctid, invokes the official openHop Proxmox installer first, then
installs a locally verified Mesh Radio Manager Debian package in the new LXC.

With --ctid, leaves LXC creation alone and installs Mesh Radio Manager into an
existing official openHop LXC.

Options:
  --manager-package PATH  Verified mesh-radio-manager_*.deb release asset.
  --apt-source-manifest FILE
                           Verified release apt-source.env. Defaults to the
                           file alongside the extracted release scripts.
  --channel alpha|beta    Meshtastic repository channel (default: alpha).
  --no-meshtastic         Do not install MeshtasticD.
  --advanced              Choose manager add-ons interactively.
  --unattended            Require --ctid and never prompt.
EOF
}

ctid=""
channel="$DEFAULT_CHANNEL"
install_meshtastic=1
manager_package=""
apt_source_manifest=""
unattended=0
advanced=0
while (($#)); do
  case "$1" in
    --ctid)
      shift
      [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || { msg_error "--ctid needs a numeric CTID"; exit 2; }
      ctid="$1"
      ;;
    --channel)
      shift
      [[ $# -gt 0 && ( "$1" == "alpha" || "$1" == "beta" ) ]] || {
        msg_error "--channel must be alpha or beta"; exit 2;
      }
      channel="$1"
      ;;
    --manager-package)
      shift
      [[ $# -gt 0 ]] || { msg_error "--manager-package needs a file path"; exit 2; }
      manager_package=$1
      ;;
    --apt-source-manifest)
      shift
      [[ $# -gt 0 ]] || { msg_error "--apt-source-manifest needs a file path"; exit 2; }
      apt_source_manifest=$1
      ;;
    --no-meshtastic) install_meshtastic=0 ;;
    --advanced) advanced=1 ;;
    --unattended) unattended=1 ;;
    -h|--help) usage; exit 0 ;;
    *) msg_error "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { msg_error "Run this from the Proxmox host as root"; exit 1; }
command -v pct >/dev/null || { msg_error "This script must run on a Proxmox VE host"; exit 1; }
command -v pveversion >/dev/null || { msg_error "pveversion is required; this must run on Proxmox VE"; exit 1; }
command -v curl >/dev/null || { msg_error "curl is required on the Proxmox host"; exit 1; }
command -v flock >/dev/null || { msg_error "flock is required on the Proxmox host"; exit 1; }
[[ -n "$manager_package" ]] || { msg_error "--manager-package is required; do not install manager code from a mutable URL"; exit 2; }
[[ -f "$manager_package" ]] || { msg_error "Manager package does not exist: $manager_package"; exit 2; }
[[ $(dpkg-deb --field "$manager_package" Package 2>/dev/null || true) == "mesh-radio-manager" ]] || {
  msg_error "--manager-package is not a mesh-radio-manager Debian package"; exit 2;
}
if [[ -z "$apt_source_manifest" ]]; then
  candidate_manifest="$(dirname -- "$script_dir")/apt-source.env"
  [[ -f "$candidate_manifest" ]] && apt_source_manifest=$candidate_manifest
fi
if [[ -n "$apt_source_manifest" && ! -r "$apt_source_manifest" ]]; then
  msg_error "APT source manifest is not readable: $apt_source_manifest"
  exit 2
fi
if ((unattended)) && [[ -z "$ctid" ]]; then
  msg_error "--unattended requires --ctid because the official openHop installer is interactive"
  exit 2
fi
if ((advanced && unattended)); then
  msg_error "--advanced and --unattended cannot be combined"
  exit 2
fi
if [[ $(pveversion) =~ ^pve-manager/([0-9]+)\.([0-9]+) ]]; then
  pve_major=${BASH_REMATCH[1]}
  pve_minor=${BASH_REMATCH[2]}
else
  msg_error "Cannot determine the Proxmox VE version"
  exit 1
fi
if ((pve_major < 8 || (pve_major == 8 && pve_minor < 4))); then
  msg_error "Proxmox VE 8.4 or newer is required"; exit 1;
fi

host_runtime_dir=/run/mesh-radio-manager
install -d -m 0750 "$host_runtime_dir"
exec 9>"$host_runtime_dir/proxmox-host-lifecycle.lock"
flock -n 9 || { msg_error "Another Mesh Radio Manager host install or update is running"; exit 1; }

if ((advanced)); then
  read -r -p "Install MeshtasticD in this LXC? [Y/n]: " meshtastic_answer
  case "$meshtastic_answer" in
    [Nn]*) install_meshtastic=0 ;;
    *) install_meshtastic=1 ;;
  esac
  if ((install_meshtastic)); then
    while :; do
      read -r -p "Meshtastic channel [alpha/beta] (alpha): " selected_channel
      selected_channel=${selected_channel:-alpha}
      case "$selected_channel" in
        alpha|beta) channel=$selected_channel; break ;;
        *) msg_warn "Choose alpha or beta." ;;
      esac
    done
  fi
fi

validate_apt_source_manifest() {
  local manifest_line seen_uri=0 seen_key_url=0 seen_fingerprint=0
  [[ -n "$apt_source_manifest" ]] || return 0
  apt_repository_uri=""
  apt_key_url=""
  apt_fingerprint=""
  while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    [[ -z "$manifest_line" || "$manifest_line" == \#* ]] && continue
    case "$manifest_line" in
      APT_URI=*)
        ((seen_uri == 0)) || { msg_error "Duplicate APT_URI in source manifest"; exit 2; }
        apt_repository_uri=${manifest_line#APT_URI=}
        seen_uri=1
        ;;
      APT_KEY_URL=*)
        ((seen_key_url == 0)) || { msg_error "Duplicate APT_KEY_URL in source manifest"; exit 2; }
        apt_key_url=${manifest_line#APT_KEY_URL=}
        seen_key_url=1
        ;;
      APT_FINGERPRINT=*)
        ((seen_fingerprint == 0)) || { msg_error "Duplicate APT_FINGERPRINT in source manifest"; exit 2; }
        apt_fingerprint=${manifest_line#APT_FINGERPRINT=}
        seen_fingerprint=1
        ;;
      *) msg_error "Unsupported entry in APT source manifest"; exit 2 ;;
    esac
  done <"$apt_source_manifest"
  ((seen_uri && seen_key_url && seen_fingerprint)) || {
    msg_error "APT source manifest must contain APT_URI, APT_KEY_URL, and APT_FINGERPRINT"
    exit 2
  }
  apt_fingerprint=${apt_fingerprint// /}
  apt_fingerprint=${apt_fingerprint^^}
  [[ "$apt_repository_uri" =~ ^https://[A-Za-z0-9._~:/-]+$ ]] || {
    msg_error "APT_URI must be a plain HTTPS URL"; exit 2;
  }
  [[ "$apt_key_url" =~ ^https://[A-Za-z0-9._~:/.-]+$ ]] || {
    msg_error "APT_KEY_URL must be a plain HTTPS URL"; exit 2;
  }
  [[ "$apt_fingerprint" =~ ^[0-9A-F]{40}$ ]] || {
    msg_error "APT_FINGERPRINT must be a 40-hex-digit primary-key fingerprint"; exit 2;
  }
}

validate_apt_source_manifest

list_ctids() {
  pct list | awk 'NR > 1 {print $1}' | sort -n
}

preflight_lxc() {
  local os_release architecture
  pct status "$ctid" >/dev/null 2>&1 || { msg_error "LXC ${ctid} does not exist"; exit 1; }
  # shellcheck disable=SC2016 # The quoted program runs inside the target LXC.
  if ! pct exec "$ctid" -- sh -ec '
    . /etc/os-release
    [ "${ID:-}" = debian ]
    [ "${VERSION_ID:-0}" -ge 13 ]
    case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) exit 1;; esac
    [ -d /root/openhop-repeater ]
    [ -f /etc/openhop_repeater/config.yaml ]
  '; then
    msg_error "LXC ${ctid} must be a Debian 13+ amd64/arm64 official openHop installation"
    exit 1
  fi
  # shellcheck disable=SC2016 # The quoted program runs inside the target LXC.
  os_release=$(pct exec "$ctid" -- sh -ec '. /etc/os-release; printf "%s %s" "$ID" "$VERSION_ID"')
  architecture=$(pct exec "$ctid" -- dpkg --print-architecture)
  msg_ok "Preflight passed: LXC ${ctid} (${os_release}, ${architecture})"
}

ensure_manager_tag() {
  local existing_tags merged_tags
  existing_tags=$(pct config "$ctid" | awk -F': ' '$1 == "tags" {print $2; exit}')
  case ";${existing_tags};" in
    *";${MANAGER_TAG};"*) return ;;
  esac
  merged_tags="${existing_tags:+${existing_tags};}${MANAGER_TAG}"
  pct set "$ctid" --tags "$merged_tags" >/dev/null
  msg_ok "Tagged LXC ${ctid} with ${MANAGER_TAG}"
}

host_quirks_changed=0
ensure_host_ch341_quirks() {
  local config_file="/etc/pve/lxc/${ctid}.conf"
  local device_allow="lxc.cgroup2.devices.allow: c 189:* rwm"
  local usb_mount="lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0"
  local upstream_rule='SUBSYSTEM=="usb", ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512", MODE="0666"'
  local rule_file="/etc/udev/rules.d/99-ch341.rules"

  [[ -f "$config_file" ]] || { msg_error "Missing Proxmox LXC configuration: $config_file"; exit 1; }
  if grep -Eq '^unprivileged:[[:space:]]*1' "$config_file"; then
    msg_error "LXC ${ctid} is unprivileged. The official openHop USB setup requires a privileged LXC."
    msg_error "Create it with the official installer instead of converting an existing LXC in place."
    exit 1
  fi

  # These are the exact USB lines used by the official openHop Proxmox
  # installer. Add only missing entries; never rewrite the rest of the CT
  # configuration managed by Proxmox/the user.
  if ! grep -Fqx "$device_allow" "$config_file"; then
    printf '\n# CH341 USB passthrough for Mesh Radio Manager\n%s\n' "$device_allow" >>"$config_file"
    host_quirks_changed=1
  fi
  if ! grep -Fqx "$usb_mount" "$config_file"; then
    printf '%s\n' "$usb_mount" >>"$config_file"
    host_quirks_changed=1
  fi

  if [[ ! -f "$rule_file" ]]; then
    printf '%s\n' "$upstream_rule" >"$rule_file"
    chmod 0644 "$rule_file"
    host_quirks_changed=1
  elif grep -Fq 'ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512"' "$rule_file"; then
    : # Preserve the official rule or a compatible existing user rule.
  else
    # Do not overwrite a user's unrelated 99-ch341.rules. An additive,
    # manager-named rule provides the same official permission quirk.
    rule_file="/etc/udev/rules.d/99-mesh-radio-manager-ch341.rules"
    if [[ ! -f "$rule_file" ]]; then
      printf '%s\n' "$upstream_rule" >"$rule_file"
      chmod 0644 "$rule_file"
      host_quirks_changed=1
    fi
  fi
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb --action=change
  msg_ok "Verified official CH341 host passthrough quirks"
}

choose_ctid() {
  local -a created=()
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && created+=("$candidate")
  done < <(comm -13 <(printf '%s\n' "$1" | sort -n) <(list_ctids))

  if ((${#created[@]} == 1)); then
    ctid="${created[0]}"
    msg_ok "Detected newly-created LXC ${ctid}"
    return
  fi
  msg_warn "Could not uniquely detect the new LXC. Select the official openHop CTID."
  pct list
  while :; do
    read -r -p " CTID: " ctid
    [[ "$ctid" =~ ^[0-9]+$ ]] && pct status "$ctid" >/dev/null 2>&1 && return
    msg_warn "That CTID does not exist."
  done
}

if [[ -z "$ctid" ]]; then
  header_before="$(list_ctids)"
  echo -e "${BLD}Mesh Radio Manager — Proxmox host installer${CL}"
  msg_info "Starting the official openHop Proxmox installer. Complete its prompts."
  # openHop remains entirely upstream-owned. Download its official installer
  # to a private file before execution; manager code is never fetched this way.
  openhop_script=$(mktemp /tmp/openhop-proxmox-installer.XXXXXX)
  trap 'rm -f "$openhop_script"' EXIT HUP INT TERM
  curl --fail --location --proto '=https' --tlsv1.2 --output "$openhop_script" "$OPENHOP_INSTALLER"
  upstream_hostname_defaults=$(grep -Fxc "$OPENHOP_DEFAULT_HOSTNAME_LINE" "$openhop_script" || true)
  if [[ "$upstream_hostname_defaults" != "1" ]]; then
    msg_error "The official openHop installer no longer has the expected hostname default."
    msg_error "Refusing to modify its prompts; run it directly and choose the hostname yourself."
    exit 1
  fi
  sed -i "s|^${OPENHOP_DEFAULT_HOSTNAME_LINE}$|${MANAGER_DEFAULT_HOSTNAME_LINE}|" "$openhop_script"
  if ! grep -Fqx "$MANAGER_DEFAULT_HOSTNAME_LINE" "$openhop_script"; then
    msg_error "Could not set the Mesh Radio Manager hostname default in the official installer."
    exit 1
  fi
  msg_info "The upstream hostname prompt now defaults to mesh-radio-manager; you may enter another name."
  bash "$openhop_script"
  choose_ctid "$header_before"
else
  pct status "$ctid" >/dev/null 2>&1 || { msg_error "LXC ${ctid} does not exist"; exit 1; }
fi

was_running=0
if pct status "$ctid" | grep -q 'status: running'; then
  was_running=1
fi
if (( ! was_running )); then
  msg_info "Starting LXC ${ctid}"
  pct start "$ctid"
fi

preflight_lxc
ensure_host_ch341_quirks
if ((host_quirks_changed)); then
  msg_info "Restarting LXC ${ctid} to apply USB passthrough changes"
  pct restart "$ctid"
fi
msg_info "Installing verified Mesh Radio Manager package in LXC ${ctid}"
pct push "$ctid" "$manager_package" /tmp/mesh-radio-manager.deb
pct exec "$ctid" -- apt-get update -qq
pct exec "$ctid" -- env DEBIAN_FRONTEND=noninteractive apt-get install --yes /tmp/mesh-radio-manager.deb
pct exec "$ctid" -- rm -f /tmp/mesh-radio-manager.deb
if [[ -n "$apt_source_manifest" ]]; then
  msg_info "Configuring the signed Mesh Radio Manager APT source"
  pct push "$ctid" "$apt_source_manifest" /tmp/mesh-radio-manager-apt-source.env
  pct exec "$ctid" -- /usr/bin/mesh-radio-apt-repository --manifest /tmp/mesh-radio-manager-apt-source.env
  pct exec "$ctid" -- rm -f /tmp/mesh-radio-manager-apt-source.env
  msg_ok "Signed manager updates are enabled"
else
  msg_warn "No apt-source.env was found; manager self-update is unavailable until a signed source is configured"
fi
if ((install_meshtastic)); then
  pct exec "$ctid" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg
  pct exec "$ctid" -- /usr/bin/mesh-radio meshtastic install --channel "$channel"
fi
pct exec "$ctid" -- /usr/bin/mesh-radio --version >/dev/null
ensure_manager_tag

msg_info "Installing Proxmox-host control panel"
if [[ -f "$script_dir/proxmox-manage.sh" ]]; then
  install -m 0755 "$script_dir/proxmox-manage.sh" /usr/local/sbin/mesh-radio-pve
  msg_ok "Host panel installed: mesh-radio-pve --ctid ${ctid}"
else
  msg_warn "LXC installation succeeded, but the release bundle lacks proxmox-manage.sh"
fi

ip_address="$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo
msg_ok "Mesh Radio Manager installation complete"
echo -e " Container: ${GN}${ctid}${CL}"
echo -e " openHop UI: ${GN}http://${ip_address:-<LXC-IP>}:8000${CL}"
echo
echo "Next: the official openHop installer has already configured USB bus passthrough."
echo "Inspect the two radios, then assign them inside the LXC:"
echo "  pct enter ${ctid}"
echo "  systemctl stop openhop-repeater meshtasticd 2>/dev/null || true"
echo "  mesh-radio radios"
echo "  mesh-radio assign openhop <selector> --profile pinedio"
echo "  mesh-radio assign meshtastic <selector> --profile meshtadpole"
echo "  mesh-radio verify"
echo "  systemctl start meshtasticd && systemctl restart openhop-repeater"
echo
echo "Later, update all three components from inside the LXC with: mesh-radio update"
echo "Or open the Proxmox-host control panel: mesh-radio-pve --ctid ${ctid}"
