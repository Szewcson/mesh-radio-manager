#!/usr/bin/env bash
# Publish an already-built manager package into a locally maintained APT archive.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: publish-apt-repository.sh --package FILE --repository DIRECTORY --fingerprint FINGERPRINT

The caller owns publication of DIRECTORY through HTTPS. Keep the signing key
outside CI (for example an offline or hardware-backed OpenPGP key). This script
never pushes to GitHub and never creates a signing key.
EOF
}

package_file=""
repository_dir=""
fingerprint=""
while (($#)); do
  case "$1" in
    --package)
      shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; package_file=$1 ;;
    --repository)
      shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; repository_dir=$1 ;;
    --fingerprint)
      shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; fingerprint=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ -f "$package_file" && -n "$repository_dir" && -n "$fingerprint" ]] || { usage >&2; exit 2; }
[[ $(dpkg-deb --field "$package_file" Package 2>/dev/null || true) = mesh-radio-manager ]] || {
  echo "--package is not a mesh-radio-manager Debian package." >&2
  exit 2
}
fingerprint=${fingerprint// /}
fingerprint=${fingerprint^^}
[[ "$fingerprint" =~ ^[0-9A-F]{40}([0-9A-F]{24})?$ ]] || { echo "Invalid OpenPGP fingerprint." >&2; exit 2; }
command -v reprepro >/dev/null || { echo "reprepro is required." >&2; exit 1; }
command -v gpg >/dev/null || { echo "gpg is required." >&2; exit 1; }
gpg --list-secret-keys --with-colons "$fingerprint" | awk -F: '$1 == "sec" {found=1} END {exit !found}' || {
  echo "The required signing key is unavailable in the current OpenPGP keyring." >&2
  exit 1
}

install -d -m 0755 "$repository_dir/conf"
distribution_file="$repository_dir/conf/distributions"
if [[ ! -f "$distribution_file" ]]; then
  printf 'Origin: Mesh Radio Manager\nLabel: Mesh Radio Manager\nCodename: stable\nSuite: stable\nArchitectures: amd64 arm64 all source\nComponents: main\nDescription: Mesh Radio Manager signed package archive\nSignWith: %s\n' \
    "$fingerprint" >"$distribution_file"
fi
reprepro --basedir "$repository_dir" includedeb stable "$package_file"
gpg --armor --export "$fingerprint" >"$repository_dir/mesh-radio-manager-archive-keyring.asc"
chmod 0644 "$repository_dir/mesh-radio-manager-archive-keyring.asc"
echo "Published signed APT archive in $repository_dir"
