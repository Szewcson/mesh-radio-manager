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
OPENHOP_PRIVILEGED_PATTERN='^[[:space:]]*--unprivileged[[:space:]]+0[[:space:]]*\\[[:space:]]*$'
OPENHOP_UNPRIVILEGED_PATTERN='^[[:space:]]*--unprivileged[[:space:]]+1[[:space:]]*\\[[:space:]]*$'
OPENHOP_CH341_PROMPT='read -p "  Install host-side CH341 udev rule? [y/N]: " -r input'
# shellcheck disable=SC2016 # This is an exact literal line in the upstream installer.
OPENHOP_CH341_SELECTION='[[ "${input:-n}" =~ ^[Yy]([Ee][Ss])?$ ]] && INSTALL_CH341_UDEV=true'
OPENHOP_MODE_SUMMARY_LINE='echo "  Mode: privileged"'
OPENHOP_UNPRIVILEGED_SUMMARY_LINE='echo "  Mode: unprivileged (device-scoped USB configured after assignment)"'
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
  --unprivileged          Create a fresh unprivileged LXC with device-scoped
                          USB access. Cannot be used with --ctid.
  --openhop-selector SEL  Preselect the host radio for openHop. Fresh
                          --unprivileged installs otherwise present a menu.
  --meshtastic-selector SEL
                          Preselect the host radio for MeshtasticD.
  --manual-radio-configuration
                          Bootstrap selected radios but do not create CT
                          assignments or finalize services automatically.
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
unprivileged=0
openhop_selector=""
meshtastic_selector=""
manual_radio_configuration=0
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
    --unprivileged) unprivileged=1 ;;
    --openhop-selector)
      shift
      [[ $# -gt 0 ]] || { msg_error "--openhop-selector needs a selector"; exit 2; }
      openhop_selector=$1
      ;;
    --meshtastic-selector)
      shift
      [[ $# -gt 0 ]] || { msg_error "--meshtastic-selector needs a selector"; exit 2; }
      meshtastic_selector=$1
      ;;
    --manual-radio-configuration) manual_radio_configuration=1 ;;
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
if ((unprivileged)) && [[ -n "$ctid" ]]; then
  msg_error "--unprivileged creates a fresh LXC only; it never converts an existing container"
  exit 2
fi
if [[ -n "$openhop_selector$meshtastic_selector" ]] && [[ -z "$openhop_selector" || -z "$meshtastic_selector" ]]; then
  msg_error "--openhop-selector and --meshtastic-selector must be used together"
  exit 2
fi
if [[ -n "$openhop_selector$meshtastic_selector" ]] && (( ! unprivileged )); then
  msg_error "Radio selectors are only used by the fresh --unprivileged flow"
  exit 2
fi
if ((manual_radio_configuration && ! unprivileged)); then
  msg_error "--manual-radio-configuration is only used by the fresh --unprivileged flow"
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

if ((unprivileged && ! install_meshtastic)); then
  msg_error "The fresh --unprivileged radio handoff requires MeshtasticD; omit --no-meshtastic."
  exit 2
fi

preflight_unprivileged_host() {
  [[ -f "$script_dir/proxmox-usb.sh" ]] || {
    msg_error "The release bundle lacks proxmox-usb.sh required for unprivileged USB setup."
    exit 1
  }
  # This executes no LXC operation. It rejects an old host-wide CH341 0666
  # rule before the new CT is created, avoiding a partially created migration.
  bash "$script_dir/proxmox-usb.sh" preflight
}

if ((unprivileged)); then
  preflight_unprivileged_host
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

select_host_radio() {
  local role=$1 excluded_selector=${2:-} listing line selector choice
  local -a selectors=() rows=()
  listing=$(bash "$script_dir/proxmox-usb.sh" list) || {
    msg_error "Could not enumerate CH341 radios on the Proxmox host."
    return 1
  }
  while IFS= read -r line; do
    [[ "$line" == SELECTOR* ]] && continue
    selector=${line%%[[:space:]]*}
    [[ "$selector" == serial:* || "$selector" == port:* ]] || continue
    [[ "$selector" != "$excluded_selector" ]] || continue
    selectors+=("$selector")
    rows+=("$line")
  done <<<"$listing"
  ((${#selectors[@]} > 0)) || {
    msg_error "No unused CH341 radio is available for ${role}."
    return 1
  }
  printf '\nSelect the %s radio from this Proxmox-host inventory:\n' "$role" >&2
  for ((choice = 0; choice < ${#selectors[@]}; choice++)); do
    printf '  %d) %s\n' "$((choice + 1))" "${rows[choice]}" >&2
  done
  while :; do
    printf ' %s choice [1-%d]: ' "$role" "${#selectors[@]}" >&2
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#selectors[@]})) && {
      printf '%s\n' "${selectors[choice - 1]}"
      return 0
    }
    msg_warn "Choose a number from 1 to ${#selectors[@]}."
  done
}

host_selector_exists() {
  local expected=$1 listing line selector matches=0
  listing=$(bash "$script_dir/proxmox-usb.sh" list) || return 1
  while IFS= read -r line; do
    selector=${line%%[[:space:]]*}
    [[ "$selector" == "$expected" ]] && matches=$((matches + 1))
  done <<<"$listing"
  [[ "$matches" == 1 ]]
}

choose_unprivileged_radios() {
  if [[ -z "$openhop_selector" ]]; then
    openhop_selector=$(select_host_radio openHop) || return 1
    meshtastic_selector=$(select_host_radio MeshtasticD "$openhop_selector") || return 1
  else
    host_selector_exists "$openhop_selector" || {
      msg_error "Requested openHop selector is not currently a unique listed host radio: $openhop_selector"
      return 1
    }
    host_selector_exists "$meshtastic_selector" || {
      msg_error "Requested MeshtasticD selector is not currently a unique listed host radio: $meshtastic_selector"
      return 1
    }
  fi
  [[ "$openhop_selector" != "$meshtastic_selector" ]] || {
    msg_error "openHop and MeshtasticD must use different radios."
    return 1
  }
  msg_info "Selected openHop=${openhop_selector}; MeshtasticD=${meshtastic_selector}"
}

configure_selected_radios_in_lxc() {
  msg_info "Passing selected host identities to the Mesh Radio Manager in LXC ${ctid}"
  # Assignments are performed only after bootstrap grants exactly these two
  # devices. The manager independently resolves each selector in the CT and
  # fails instead of translating a topology path heuristically.
  pct exec "$ctid" -- sh -ec 'systemctl stop openhop-repeater meshtasticd 2>/dev/null || true'
  pct exec "$ctid" -- /usr/bin/mesh-radio assign openhop "$openhop_selector" --profile pinedio
  pct exec "$ctid" -- /usr/bin/mesh-radio assign meshtastic "$meshtastic_selector" --profile meshtadpole
  pct exec "$ctid" -- /usr/bin/mesh-radio verify >/dev/null
  msg_ok "Selected radios were assigned and verified inside LXC ${ctid}"
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
    msg_ok "Unprivileged LXC detected: broad USB compatibility rules are intentionally not installed"
    return
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

patch_upstream_for_unprivileged_lxc() {
  local temporary mode_count mode_context_count usb_start_count container_start_count
  local ch341_prompt_count ch341_selection_count mode_summary_count
  mode_count=$(grep -Ec "$OPENHOP_PRIVILEGED_PATTERN" "$openhop_script" || true)
  mode_context_count=$(awk '
    /^pct create "\$CTID"/ { creates += 1; inside = 1; next }
    inside && /^[[:space:]]*--unprivileged[[:space:]]+0[[:space:]]*\\[[:space:]]*$/ { modes += 1 }
    inside && /^[[:space:]]*--ostype[[:space:]]+debian[[:space:]]*$/ { ends += 1; inside = 0 }
    END {
      if (creates == 1 && ends == 1 && modes == 1 && !inside) print 1
      else print 0
    }
  ' "$openhop_script")
  if [[ "$mode_count" != 1 || "$mode_context_count" != 1 ]]; then
    msg_error "The official openHop installer no longer has the expected privileged-LXC creation line."
    msg_error "Refusing to guess at an unprivileged conversion."
    exit 1
  fi
  usb_start_count=$(grep -Fc '# ── USB passthrough' "$openhop_script" || true)
  container_start_count=$(grep -Fc '# ── Start container' "$openhop_script" || true)
  if [[ "$usb_start_count" != 1 || "$container_start_count" != 1 ]]; then
    msg_error "The official openHop installer USB section no longer has the expected boundaries."
    msg_error "Refusing to guess at an unprivileged USB policy."
    exit 1
  fi
  ch341_prompt_count=$(grep -Fxc "$OPENHOP_CH341_PROMPT" "$openhop_script" || true)
  ch341_selection_count=$(grep -Fxc "$OPENHOP_CH341_SELECTION" "$openhop_script" || true)
  mode_summary_count=$(grep -Fxc "$OPENHOP_MODE_SUMMARY_LINE" "$openhop_script" || true)
  if [[ "$ch341_prompt_count" != 1 || "$ch341_selection_count" != 1 || "$mode_summary_count" != 1 ]]; then
    msg_error "The official openHop installer interactive USB choices changed."
    msg_error "Refusing to leave a misleading or unsafe unprivileged prompt."
    exit 1
  fi
  temporary=$(mktemp "${openhop_script}.unprivileged.XXXXXX")
  if ! awk '
    /^[[:space:]]*--unprivileged[[:space:]]+0[[:space:]]*\\[[:space:]]*$/ {
      sub(/--unprivileged[[:space:]]+0/, "--unprivileged 1")
      replacements += 1
    }
    { print }
    END { exit replacements != 1 }
  ' "$openhop_script" >"$temporary"; then
    rm -f -- "$temporary"
    msg_error "Could not set unprivileged LXC mode in the official installer."
    exit 1
  fi
  mv -f -- "$temporary" "$openhop_script"
  # The upstream script's USBFS wildcard and MODE=0666 rule are valid only
  # for its privileged mode. Require both policies inside the one identified
  # section before deleting it, then provision two narrow devN grants later.
  if ! awk '
    index($0, "# ── USB passthrough") == 1 { if (inside) exit 1; inside = 1; starts += 1; next }
    inside && index($0, "# ── Start container") == 1 { inside = 0; ends += 1 }
    inside && index($0, "lxc.cgroup2.devices.allow: c 189:* rwm") { wildcard += 1 }
    inside && index($0, "ATTR{idVendor}==\"1a86\", ATTR{idProduct}==\"5512\", MODE=\"0666\"") { broad_rule += 1 }
    !inside { print }
    END { exit starts != 1 || ends != 1 || inside || wildcard != 1 || broad_rule != 1 }
  ' "$openhop_script" >"$temporary"; then
    rm -f -- "$temporary"
    msg_error "Could not remove the official USB compatibility section."
    exit 1
  fi
  mv -f -- "$temporary" "$openhop_script"
  if ! awk -v prompt="$OPENHOP_CH341_PROMPT" -v selection="$OPENHOP_CH341_SELECTION" '
    $0 == prompt || $0 == selection { removed += 1; next }
    { print }
    END { exit removed != 2 }
  ' "$openhop_script" >"$temporary"; then
    rm -f -- "$temporary"
    msg_error "Could not disable the official broad CH341 prompt."
    exit 1
  fi
  mv -f -- "$temporary" "$openhop_script"
  if ! awk -v expected="$OPENHOP_MODE_SUMMARY_LINE" -v replacement="$OPENHOP_UNPRIVILEGED_SUMMARY_LINE" '
    $0 == expected { print replacement; replacements += 1; next }
    { print }
    END { exit replacements != 1 }
  ' "$openhop_script" >"$temporary"; then
    rm -f -- "$temporary"
    msg_error "Could not update the official installer mode summary."
    exit 1
  fi
  mv -f -- "$temporary" "$openhop_script"
  grep -Eq "$OPENHOP_UNPRIVILEGED_PATTERN" "$openhop_script" || {
    msg_error "Could not set unprivileged LXC mode in the official installer."
    exit 1
  }
  grep -Fqx "$OPENHOP_UNPRIVILEGED_SUMMARY_LINE" "$openhop_script" || {
    msg_error "Could not update the official installer mode summary."
    exit 1
  }
  if grep -Fq 'lxc.cgroup2.devices.allow: c 189:* rwm' "$openhop_script" ||
    grep -Fq 'ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512", MODE="0666"' "$openhop_script"; then
    msg_error "The official installer USB compatibility block changed; refusing an incomplete unprivileged setup."
    exit 1
  fi
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

if ((unprivileged)); then
  choose_unprivileged_radios
fi

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
  if ((unprivileged)); then
    patch_upstream_for_unprivileged_lxc
    msg_info "The fresh LXC will be unprivileged. USB is added only later as two device-scoped grants."
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
if [[ -f "$script_dir/proxmox-manage.sh" && -f "$script_dir/proxmox-usb.sh" ]]; then
  install -d -m 0755 /usr/local/lib/mesh-radio-manager
  install -m 0755 "$script_dir/proxmox-usb.sh" /usr/local/lib/mesh-radio-manager/proxmox-usb.sh
  install -m 0755 "$script_dir/proxmox-manage.sh" /usr/local/sbin/mesh-radio-pve
  msg_ok "Host panel installed: mesh-radio-pve --ctid ${ctid}"
else
  msg_warn "LXC installation succeeded, but the release bundle lacks a Proxmox host helper"
  if ((unprivileged)); then
    msg_error "Cannot continue an unprivileged install without the bundled host helper."
    exit 1
  fi
fi

if ((unprivileged)); then
  msg_info "Bootstrapping exactly the selected USB radios into unprivileged LXC ${ctid}"
  bash "$script_dir/proxmox-usb.sh" bootstrap --ctid "$ctid" \
    --openhop-selector "$openhop_selector" --meshtastic-selector "$meshtastic_selector" --yes
  if ((manual_radio_configuration)); then
    msg_warn "Radio handoff is bootstrapped only; assignments and final validation were left for manual configuration."
  else
    if ! configure_selected_radios_in_lxc; then
      msg_error "Automatic CT assignment failed. The CT retains only bootstrap access to the two selected radios."
      msg_error "Inspect 'mesh-radio radios' in CT ${ctid}, assign manually, then run mesh-radio-pve --secure-usb with the selected selectors."
      exit 1
    fi
    msg_info "Finalizing device-scoped USB access and restarting LXC ${ctid}"
    if ! bash "$script_dir/proxmox-usb.sh" secure --ctid "$ctid" \
      --openhop-selector "$openhop_selector" --meshtastic-selector "$meshtastic_selector" --yes; then
      msg_error "Automatic finalization failed; the CT remains in its previously recorded bootstrap state."
      exit 1
    fi
  fi
fi

ip_address="$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo
msg_ok "Mesh Radio Manager installation complete"
echo -e " Container: ${GN}${ctid}${CL}"
echo -e " openHop UI: ${GN}http://${ip_address:-<LXC-IP>}:8000${CL}"
echo
if ((unprivileged)); then
  if ((manual_radio_configuration)); then
    echo "The selected radios have bootstrap-only access. Configure manually inside the LXC, then finalize from PVE:"
    echo "  mesh-radio-pve --ctid ${ctid} --secure-usb --openhop-selector '${openhop_selector}' --meshtastic-selector '${meshtastic_selector}' --yes"
  else
    echo "The selected radios were assigned and finalized with device-scoped USB access."
    echo "Set your Meshtastic node region/settings, then enable or restart the radio services as desired."
  fi
else
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
  echo "Then return to the Proxmox host and replace broad USB compatibility access:"
  echo "  mesh-radio-pve --usb-devices"
  echo "  mesh-radio-pve --ctid ${ctid} --secure-usb --openhop-selector '<port:...>' --meshtastic-selector '<serial:...>' --yes"
  echo "This retains USBFS visibility for libusb but permits only the assigned radios."
fi
echo
echo "Later, update all three components from inside the LXC with: mesh-radio update"
echo "Or open the Proxmox-host control panel: mesh-radio-pve --ctid ${ctid}"
