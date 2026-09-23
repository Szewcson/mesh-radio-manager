# GitHub-hosted signed APT repository

The release workflow makes a tagged release a complete update transaction:

1. it tests and builds `mesh-radio-manager_*.deb`;
2. it produces GitHub build attestations for the package and release bundle;
3. it signs a Debian APT archive with the dedicated archive key;
4. it publishes that archive on this repository's GitHub Pages site; and
5. only after Pages deployment succeeds, it publishes the GitHub Release and
   its `apt-source.env` manifest.

The Proxmox installer consumes the `apt-source.env` that is inside an
attestation-verified release bundle. It never executes it: it parses the three
expected values, downloads the public key over HTTPS, checks its exact OpenPGP
fingerprint, and writes an APT source limited with `Signed-By` to that key.
Therefore `mesh-radio manager update` uses normal APT package updates rather
than Git, a release-download script, or a mutable branch.

## One-time repository-owner setup

This setup must be completed before creating the first release tag. The
workflow fails closed if any required signing configuration is absent; it will
not publish an unsigned archive or a release that claims updates are ready.

Create a dedicated signing key, distinct from any personal identity or SSH key.
The key is an online package-release key, so use an expiry and plan a rotation;
do not reuse it for email, commits, or other repositories.

Keep the base64 private-key export in an external secret manager and provide a
separately encrypted copy only to the protected GitHub release environment. Do
not store archive-key material in this repository or a normal workstation GnuPG
keyring. The release runner imports the environment secret into a job-private
temporary GnuPG home and removes it after archive signing.

In the GitHub repository settings:

- Create a protected `release` environment and allow only `v*` release tags to
  deploy to it. Add a required reviewer when a separate maintainer is
  available; do not require self-review on a sole-maintainer repository.
- Add the base64 private-key export as the environment secret
  `APT_GPG_PRIVATE_KEY_BASE64`.
- Add the printed primary fingerprint as repository variable
  `APT_GPG_FINGERPRINT`.
- Enable GitHub Pages with **GitHub Actions** as its publishing source. Protect
  the automatically created `github-pages` environment so only the release
  workflow can deploy.

The default public archive address is:

```text
https://szewcson.github.io/mesh-radio-manager/apt
```

If you use a custom HTTPS domain, set repository variable `APT_PUBLIC_URI` to
the exact archive path, for example `https://packages.example.org/apt`. The
workflow writes it, its key URL, and the expected fingerprint into each
release's `apt-source.env`.

This GitHub-hosted workflow cannot use a non-exportable hardware key directly.
For hardware-backed signing, run the same build/publish workflow on a protected
self-hosted runner that can access that key, or use a separate signing service.
Do not put an offline root key, a personal signing key, or a hardware-token PIN
in GitHub Actions secrets.

## Publishing a release

After review, set the package version in `pyproject.toml` and
`debian/changelog`, commit the change, and create a matching signed tag:

```bash
git tag -a v0.1.2 -m 'Mesh Radio Manager v0.1.2'
git push origin v0.1.2
```

The workflow requires the tag and Python package version to agree. It builds
the archive from the current package plus up to 100 earlier GitHub Release
packages, preserving ordinary APT rollback/version selection. A failed Pages
deployment prevents publication of the release assets; investigate and rerun
the same protected tag after fixing the configuration.

## Client setup and update

For a new Proxmox installation, extract and attest the release bundle exactly
as described in the main README. `scripts/proxmox-install.sh` finds its adjacent
`apt-source.env` and configures the source inside the LXC automatically.

For a manual package installation, use the manifest from that same verified
bundle:

```bash
sudo apt-get install ./mesh-radio-manager_0.1.2-1_all.deb
sudo mesh-radio-apt-repository --manifest ./apt-source.env
sudo mesh-radio manager update
```

Inspect the source and key before trusting a new archive:

```bash
cat /etc/apt/sources.list.d/mesh-radio-manager.sources
gpg --show-keys --fingerprint /usr/share/keyrings/mesh-radio-manager-archive-keyring.gpg
apt-cache policy mesh-radio-manager
```

The installed source is HTTPS-only and scoped to the dedicated archive key. A
key rotation is a manual, reviewed migration: publish a transition release,
configure the replacement key, verify it out of band, and only then retire the
old key. Never silently replace an installed archive key.

## Private or offline deployments

For a private HTTPS server or disconnected environment, keep using
`scripts/publish-apt-repository.sh` with a dedicated key held outside CI. It
does not push to GitHub. Configure the resulting source with
`mesh-radio-apt-repository --uri ... --key-url ... --fingerprint ...` after
independently verifying the fingerprint.
