# Mesh Radio Manager

Mesh Radio Manager is an independent companion project for managing multiple
Linux USB LoRa radios and running services such as openHop/MeshCore and
Meshtastic side-by-side.

It is **not** an openHop fork and does not redistribute openHop. Install
openHop with the official instructions from
[`openhop-dev/openhop_repeater`](https://github.com/openhop-dev/openhop_repeater)
first; openHop updates remain managed by upstream.

```text
HAOS VM
  |
  +-- MeshCore integration -- TCP 5000 -- openHop -- PineDio
  |
  +-- Meshtastic integration - TCP 4403 -- meshtasticd -- MeshTadpole

Debian LXC
  |
  +-- upstream openHop (/root/openhop-repeater, untouched)
  +-- meshtasticd
  +-- Mesh Radio Manager -- USB assignment and safety checks
```

## Install

### Verified Proxmox host installer (recommended)

Use a versioned release bundle, not a mutable `main` branch script. Download
the bundle and verify its GitHub build provenance before extracting it:

```bash
VERSION=v0.1.11
PACKAGE_VERSION=${VERSION#v}
curl --fail --location --proto '=https' --tlsv1.2 -O \
  "https://github.com/Szewcson/mesh-radio-manager/releases/download/${VERSION}/mesh-radio-manager-${VERSION}.tar.gz"
gh attestation verify "mesh-radio-manager-${VERSION}.tar.gz" -R Szewcson/mesh-radio-manager
tar -xzf "mesh-radio-manager-${VERSION}.tar.gz"
cd mesh-radio-manager
```

From the **Proxmox host shell** as root, create a new official openHop LXC and
install the verified manager package bundled with that release:

```bash
./scripts/proxmox-install.sh \
  --manager-package "./mesh-radio-manager_${PACKAGE_VERSION}-1_all.deb" \
  --channel alpha
```

For an existing official openHop LXC, provide its CTID instead:

```bash
./scripts/proxmox-install.sh --ctid 103 \
  --manager-package "./mesh-radio-manager_${PACKAGE_VERSION}-1_all.deb" \
  --channel alpha --unattended
```

The helper reuses the official openHop installer without copying it into this
project. For a new LXC it modifies only the exact upstream hostname-default
line in its temporary download; if that line changes upstream, the helper stops
instead of guessing. The original hostname prompt remains interactive and now
defaults to `mesh-radio-manager`, so you may enter a different name. It verifies
PVE 8.4+, a Debian 13+ official openHop LXC, and architecture before changing
the LXC. The default mode preserves upstream's privileged USB compatibility;
the fresh `--unprivileged` mode uses the device-scoped flow below instead. It
tags successful containers `mesh-radio-manager`.
The default profile uses Meshtastic alpha; use
`--advanced` to choose the Meshtastic add-on/channel interactively, or use
explicit flags with `--unattended` for automation. A published release bundle
also contains `apt-source.env`; after you verify the bundle attestation, the
helper automatically pins the signed GitHub Pages APT repository. Future
`mesh-radio manager update` calls then download the Debian package from that
repository rather than from a mutable script.

### Fresh unprivileged LXC (recommended)

For a new installation, add `--unprivileged`. This is a fresh-create mode only:
it cannot be combined with `--ctid`, does not convert an existing container,
and deliberately removes the upstream installer's broad USB compatibility
block before it runs.

```bash
./scripts/proxmox-install.sh \
  --manager-package "./mesh-radio-manager_${PACKAGE_VERSION}-1_all.deb" \
  --channel alpha --unprivileged
```

Before creating the CT, the installer presents the host CH341 inventory and you
select one radio for openHop and one for MeshtasticD. It then bootstraps only
those two devices, passes the selected identities to `mesh-radio assign` inside
the CT with the PineDio/MeshTadpole profiles, verifies them, and finalizes the
device grants. To preselect instead of using the menu, pass both
`--openhop-selector` and `--meshtastic-selector`. Add
`--manual-radio-configuration` to stop after bootstrap and configure the CT
yourself. The flow maps the container's `plugdev` GID through its actual
`/proc/1/gid_map`, grants only the two selected USB character devices with PVE
`devN`, and gives no world-writable CH341 host rule. It fails rather than
guessing if the container’s user/group mapping changes.

### Proxmox-style operator helpers

The host installer adds `mesh-radio-pve --ctid <CTID>` to the Proxmox host: a
terminal control panel for status, radios, validation, redacted diagnostics,
logs, service restarts, LXC shell access, and the one-command update. It also
supports tagged bulk updates and optional snapshot backups:

```bash
mesh-radio-pve --all --update --yes --backup --backup-storage local
```

Only containers tagged `mesh-radio-manager` are selected; this project never
uses Community Scripts’ tags. The LXC itself displays a compact login banner
and provides `mesh-radio-menu`. These are intentionally terminal helpers; this
project does not patch Proxmox's GUI navigation or impersonate an official
Community Scripts catalogue entry.

The host helper preserves a stopped LXC's state, validates backup storage, and
restores the exact pre-update snapshot if an update fails. Use
`mesh-radio-pve --all --dry-run` to inspect candidates without changing them,
and `mesh-radio-pve --doctor` after removing LXCs. Once no manager-tagged LXC
remains, `mesh-radio-pve --prune --yes` removes the no-longer-needed host helper.

### Device-scoped USB access

The default upstream openHop installer initially uses a compatibility USBFS bind
mount, `c 189:*`, and a broad CH341 udev rule. That makes first setup reliable,
but a privileged LXC could open other USBFS character devices. The fresh
`--unprivileged` mode never adds those rules. The fresh installer does this
selection/bootstrap/assignment/finalization automatically. The host commands
below remain available for a manual bootstrap or later inspection:

```bash
mesh-radio-pve --usb-devices

# Copy the two selectors reported immediately above. Fresh unprivileged LXC:
mesh-radio-pve --ctid 103 --bootstrap-usb \
  --openhop-selector 'port:pci0000:00/0000:00:10.0/ports/2' \
  --meshtastic-selector 'serial:12345678' --yes

# Assign both radios inside the LXC, then finalize the same two selectors:
mesh-radio-pve --ctid 103 --secure-usb \
  --openhop-selector 'port:pci0000:00/0000:00:10.0/ports/2' \
  --meshtastic-selector 'serial:12345678' --yes

mesh-radio-pve --ctid 103 --usb-status
```

`--secure-usb` stops and starts the container. It creates host udev aliases
matched by CH341 VID:PID, physical `ID_PATH`, and—where available—the USB
serial. PVE `devN` entries then grant the container only those exact USBFS
major/minor devices; the USBFS mount remains solely because both radio stacks
use libusb. The physical path is checked even for a serial-numbered radio, so
a duplicate serial on another port cannot silently take over. The helper only
accepts safe metadata for udev rules, verifies the host/LXC `plugdev` GID
mapping, and keeps the broad policy if its pre-hardening validation fails.
For an unprivileged LXC, the host rule uses the shifted numeric GID that maps
to its `plugdev` group; both radio services receive that group. It does not
rely on host root being container root.

USB bus and device numbers may change after a host reboot. They are deliberately
not saved: PVE resolves the stable host aliases each time the LXC starts. If a
radio is unplugged and reattached to the same physical port while its LXC is
running, refresh its exact device grants:

```bash
mesh-radio-pve --ctid 103 --refresh-usb --yes
```

If a radio moves to a different port, validation fails closed. Run the same
`--secure-usb` command again with the new selectors; it reconfigures the
existing narrow grants and rolls back the udev identity if validation fails.
`--refresh-usb` preserves a stopped container's state, so start it separately
after a successful refresh when that is intentional. If an autostart races
host udev settling after a reboot, it fails without a radio grant; wait for the
aliases and start the LXC again rather than restoring the broad rule.

An unprivileged deployment intentionally refuses to bootstrap while another
`MODE="0666"` CH341 host rule exists. This prevents an older, privileged
deployment from silently keeping all CH341 radios world-accessible. After that
older CT is retired, remove its upstream CH341 rule (or finish its existing
`--secure-usb` hardening) before creating the new CT; no existing CT is
converted by this project.

### Manual LXC installer

Create the LXC with the official openHop installer. Inside that LXC, install a
verified release package:

```bash
sudo apt-get install "./mesh-radio-manager_${PACKAGE_VERSION}-1_all.deb"
```

The package preserves `/etc/openhop_repeater/config.yaml`, writes manager state
below `/etc/mesh-radio-manager`, `/var/lib/mesh-radio-manager`, and
`/var/log/mesh-radio-manager`, and installs systemd **drop-ins** only. It does
not change `/root/openhop-repeater` or `/opt/openhop_repeater`. The checked-out
`./install.sh` remains a developer/local path: it creates and validates a full
new generation before atomically switching new manager processes to it.

When installing manually from the verified release bundle, configure the
matching signed source before using self-update:

```bash
sudo mesh-radio-apt-repository --manifest ./apt-source.env
```

The helper parses that manifest as data, downloads the archive public key over
HTTPS, and verifies its exact fingerprint before it writes an APT source.

Install MeshtasticD separately after package installation:

```bash
sudo apt-get install -y gnupg
sudo mesh-radio meshtastic install --channel alpha
```

This never changes RF region, power, or PSKs.

## First deployment

```bash
sudo mesh-radio radios
# Choose the displayed selector (USB serial is preferred).
sudo mesh-radio assign openhop path:4-2 --profile pinedio
sudo mesh-radio assign meshtastic serial:12345678 --profile meshtadpole
sudo mesh-radio verify
sudo mesh-radio meshtastic configure
sudo mesh-radio meshtastic restart
sudo mesh-radio openhop restart
```

`assign` refuses live reassignment while either radio daemon runs. It also
rejects any same-radio assignment. A serial is persistent; otherwise the
manager uses stable controller/port topology. If neither exists, it accepts
the assignment only while exactly one matching, no-serial radio is present.
USB bus/address is shown for diagnosis only and is never saved as identity.

The optional status UI is deliberately loopback-only by default:

```bash
sudo mesh-radio web enable
# tunnel or change /etc/mesh-radio-manager/config.yaml host deliberately
```

It is a read-only diagnostics dashboard in this initial release; the CLI is
the authenticated administrator interface for assignments and service control.

### MeshtasticD web UI

The upstream MeshtasticD HTTPS web UI is separate from this manager's
diagnostics page and is disabled by default. Enable it explicitly after the
radio assignment is healthy:

```bash
mesh-radio meshtastic web enable
mesh-radio meshtastic web status
```

It uses `https://<LXC-IP>:9443` by default. The daemon generates a local TLS
certificate if none exists, so a browser warning is expected on first access.
The manager refuses ports used by the Meshtastic TCP API (`4403`), openHop
(`8000`), or its own dashboard (`8001`), and checks live listeners before
restarting MeshtasticD. A different unused HTTPS port can be selected with
`mesh-radio meshtastic web enable --port <PORT>`; verify the resulting page and
API connection after changing it. Disable it with
`mesh-radio meshtastic web disable`.

For vetted non-hardware Meshtastic settings (such as settings documented by
the installed meshtasticd version), use
`mesh-radio meshtastic configure --advanced-file settings.yaml`. A `Lora`
or `Webserver` block is rejected because GPIO/USB ownership and web-port
conflict checking belong to the manager. Region/power are deliberately not
silently set by this project; configure them through the Meshtastic node/API
after choosing the legal local region.

## Operations

```bash
mesh-radio status
mesh-radio radios
mesh-radio verify
mesh-radio diagnose > mesh-radio-diagnose.txt
mesh-radio logs openhop
mesh-radio logs meshtastic
mesh-radio meshtastic upgrade        # displays versions, backs up config, asks
mesh-radio update                    # official openHop, signed manager package, meshtasticd
mesh-radio manager update            # signed manager Debian package only
```

`mesh-radio update` is the one-command LXC update path. It runs the official
`/root/openhop-repeater/manage.sh upgrade` first, then updates Mesh Radio
Manager and meshtasticd. It does not copy, replace, or patch that openHop
updater. Before and after updating, `mesh-radio verify` reports the exact
upstream branch, commit, and whether `/root/openhop-repeater` is clean.

`mesh-radio manager update` updates only Mesh Radio Manager through APT. It
refuses non-package installations and serializes installation/update work with
an exclusive lock. The verified GitHub release bundle configures the signed
GitHub Pages repository automatically through the Proxmox installer; direct
`.deb` installation is intended for initial deployment or a controlled offline
update. It does not run the openHop updater or upgrade MeshtasticD.

The tag-release workflow builds the package, creates GitHub provenance
attestations, signs the APT metadata, publishes the static archive on GitHub
Pages, and then creates the GitHub Release. Its one-time repository-owner setup
is documented in [docs/apt-repository.md](docs/apt-repository.md).

The final Meshtastic phase shows the installed and candidate meshtasticd versions,
then upgrades meshtasticd automatically after updating the manager. The
meshtasticd upgrade backs up `/etc/meshtasticd/config.yaml` under
`/var/lib/mesh-radio-manager/backups` before calling apt. This is deliberately
separate from the official openHop update command.

To remove only this project:

```bash
sudo apt remove mesh-radio-manager
```

This removes manager-owned integration and leaves openHop, meshtasticd, and
their configurations in place. The checked-out `./uninstall.sh` is only for a
developer/local staged installation.

## Systemd design and limitation

`20-mesh-radio-manager.conf` adds an `ExecStartPre` that validates the openHop
assignment and updates only the dynamic CH341 USB selector in
`/etc/openhop_repeater/config.yaml`. It deliberately leaves upstream's original
`ExecStart` in place: the openHop dashboard therefore continues to save its
password, API token, and all normal settings to its canonical persistent
configuration. The installer verifies that the known upstream unit command is
present before enabling this integration. If upstream changes its unit
contract, disable the drop-in and update this manager before continuing.

The meshtasticd drop-in starts a manager wrapper in a private mount namespace.
The wrapper validates exclusive assignment, generates manager-owned effective
YAML, and always isolates its mount namespace to the assigned USBFS node—even
when it also passes MeshtasticD an upstream USB serial selector. This is
intentionally not based on startup order.

Meshtastic hardware fields are limited to profiles verified against current
upstream Meshtastic configuration sources. Generic CH341/SX1262 needs explicit
verified pin mapping. Meshtastic region remains node configuration and is not
silently selected by this project.

The MeshTadpole profile is taken from Meshtastic's
[`lora-usb-meshtoad-e22.yaml`](https://raw.githubusercontent.com/meshtastic/firmware/develop/bin/config.d/lora-usb-meshtoad-e22.yaml),
including its optional `USB_Serialnum` multi-radio selector. PineDio uses the
current upstream `lora-pinedio-usb-sx1262.yaml` profile, which upstream marks
as **deprecated**; it remains available for existing hardware but should be
validated carefully after every Meshtastic update.
