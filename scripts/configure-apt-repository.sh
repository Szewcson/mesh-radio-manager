#!/usr/bin/env bash
# Install a narrowly trusted Mesh Radio Manager APT source inside an LXC.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: configure-apt-repository.sh --uri HTTPS_URI --key-url HTTPS_URL --fingerprint FINGERPRINT
       configure-apt-repository.sh --manifest RELEASE_APT_SOURCE_ENV

Downloads an ASCII-armored archive key over HTTPS, verifies its exact OpenPGP
fingerprint before trusting it, then writes a dedicated deb822 source file.
The manifest form parses only APT_URI, APT_KEY_URL, and APT_FINGERPRINT; it
never sources shell code.
EOF
}

repository_uri=""
key_url=""
expected_fingerprint=""
manifest_file=""
while (($#)); do
  case "$1" in
    --uri)
      shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; repository_uri=$1 ;;
    --key-url)
      shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; key_url=$1 ;;
    --fingerprint)
      shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; expected_fingerprint=$1 ;;
    --manifest)
      shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; manifest_file=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
if [[ -n "$manifest_file" ]]; then
  [[ -z "$repository_uri$key_url$expected_fingerprint" ]] || {
    echo "--manifest cannot be combined with --uri, --key-url, or --fingerprint." >&2
    exit 2
  }
  [[ -r "$manifest_file" && -f "$manifest_file" ]] || {
    echo "APT source manifest is not a readable regular file: $manifest_file" >&2
    exit 2
  }
  seen_uri=0
  seen_key_url=0
  seen_fingerprint=0
  while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    [[ -z "$manifest_line" || "$manifest_line" == \#* ]] && continue
    case "$manifest_line" in
      APT_URI=*)
        ((seen_uri == 0)) || { echo "Duplicate APT_URI in source manifest." >&2; exit 2; }
        repository_uri=${manifest_line#APT_URI=}
        seen_uri=1
        ;;
      APT_KEY_URL=*)
        ((seen_key_url == 0)) || { echo "Duplicate APT_KEY_URL in source manifest." >&2; exit 2; }
        key_url=${manifest_line#APT_KEY_URL=}
        seen_key_url=1
        ;;
      APT_FINGERPRINT=*)
        ((seen_fingerprint == 0)) || { echo "Duplicate APT_FINGERPRINT in source manifest." >&2; exit 2; }
        expected_fingerprint=${manifest_line#APT_FINGERPRINT=}
        seen_fingerprint=1
        ;;
      *)
        echo "Unsupported entry in APT source manifest." >&2
        exit 2
        ;;
    esac
  done <"$manifest_file"
  ((seen_uri && seen_key_url && seen_fingerprint)) || {
    echo "APT source manifest must contain APT_URI, APT_KEY_URL, and APT_FINGERPRINT." >&2
    exit 2
  }
fi
[[ "$repository_uri" =~ ^https://[A-Za-z0-9._~:/-]+$ ]] || { echo "--uri must be HTTPS." >&2; exit 2; }
case "$key_url" in
  https://*) ;;
  *) echo "--key-url must be HTTPS." >&2; exit 2 ;;
esac
[[ "$key_url" != *[[:space:]]* ]] || { echo "--key-url must not contain whitespace." >&2; exit 2; }
expected_fingerprint=${expected_fingerprint// /}
expected_fingerprint=${expected_fingerprint^^}
[[ "$expected_fingerprint" =~ ^[0-9A-F]{40}([0-9A-F]{24})?$ ]] || {
  echo "--fingerprint must be a 40- or 64-hex-digit OpenPGP fingerprint." >&2
  exit 2
}
command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v gpg >/dev/null || { echo "gpg is required; install gnupg first." >&2; exit 1; }
command -v flock >/dev/null || { echo "flock is required." >&2; exit 1; }

runtime_dir=/run/mesh-radio-manager
install -d -m 0750 "$runtime_dir"
exec 9>"$runtime_dir/package-lifecycle.lock"
flock -n 9 || {
  echo "Another Mesh Radio Manager source configuration is already running." >&2
  exit 1
}

temporary_dir=$(mktemp -d /tmp/mesh-radio-apt-key.XXXXXX)
cleanup() { rm -rf "$temporary_dir"; }
trap cleanup EXIT HUP INT TERM

key_file="$temporary_dir/archive-key.asc"
keyring_file="$temporary_dir/archive-key.gpg"
gnupg_home="$temporary_dir/gnupg"
install -d -m 0700 "$gnupg_home"
curl --fail --location --proto '=https' --tlsv1.2 --max-filesize 1048576 --output "$key_file" "$key_url"
actual_fingerprint=$(GNUPGHOME="$gnupg_home" gpg --batch --show-keys --with-colons "$key_file" | awk -F: '$1 == "fpr" {print toupper($10); exit}')
[[ "$actual_fingerprint" = "$expected_fingerprint" ]] || {
  echo "Archive key fingerprint mismatch; refusing to configure APT." >&2
  exit 1
}
GNUPGHOME="$gnupg_home" gpg --batch --dearmor --yes --output "$keyring_file" "$key_file"

keyring_dir=/usr/share/keyrings
sources_dir=/etc/apt/sources.list.d
keyring_path="$keyring_dir/mesh-radio-manager-archive-keyring.gpg"
source_path="$sources_dir/mesh-radio-manager.sources"
install -d -m 0755 "$keyring_dir" "$sources_dir"
install -m 0644 "$keyring_file" "$keyring_path"
source_temporary=$(mktemp "$sources_dir/.mesh-radio-manager.sources.XXXXXX")
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nSigned-By: %s\n' \
  "$repository_uri" "$keyring_path" >"$source_temporary"
chmod 0644 "$source_temporary"
mv -f "$source_temporary" "$source_path"
apt-get update
echo "Configured signed Mesh Radio Manager APT source: $repository_uri"
