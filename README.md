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

### Proxmox host installer (recommended)

Run this once from the **Proxmox host shell** as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Szewcson/mesh-radio-manager/main/scripts/proxmox-install.sh)"
```

It follows the familiar Proxmox VE Helper-Scripts interactive style. It invokes
the official upstream openHop Proxmox installer—without copying or changing
it—detects the new CTID, then uses `pct exec` to install Mesh Radio Manager and
Meshtastic alpha in that LXC. The official installer configures the privileged
LXC and USB bus passthrough; this helper never edits the openHop checkout. For
an existing CTID it idempotently verifies/reuses the official host quirks:
CH341 udev permissions, `c 189:* rwm`, and the `/dev/bus/usb` LXC bind mount.
It refuses an unprivileged LXC rather than attempting an unsafe conversion.

For an existing official openHop LXC, run this from the Proxmox host instead:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Szewcson/mesh-radio-manager/main/scripts/proxmox-install.sh)" -- --ctid <CTID> --channel alpha
```

Use `--no-meshtastic` to install only the manager integration.

### Proxmox-style operator helpers

The host installer adds `mesh-radio-pve --ctid <CTID>` to the Proxmox host: a
terminal control panel for status, radios, validation, redacted diagnostics,
logs, service restarts, LXC shell access, and the one-command update. The LXC
itself displays a compact login banner and provides `mesh-radio-menu` with the
same operations. These are intentionally terminal helpers; this project does
not patch Proxmox's GUI navigation or impersonate an official Community
Scripts catalogue entry.

### Manual LXC installer

Create the LXC with the official openHop installer. Inside that LXC, clone or
download a release of this project, then run:

```bash
sudo ./install.sh
```

The installer refuses to recreate openHop when it is absent. It preserves
`/etc/openhop_repeater/config.yaml`, writes manager state below
`/etc/mesh-radio-manager`, `/var/lib/mesh-radio-manager`, and
`/var/log/mesh-radio-manager`, and installs systemd **drop-ins** only. It does
not change `/root/openhop-repeater` or `/opt/openhop_repeater`.

For a published release the same installer can be used as:

```bash
curl -fsSL https://github.com/Szewcson/mesh-radio-manager/releases/latest/download/install.sh | sudo bash
```

The release installer downloads this project only; it never vendors openHop.

`./install.sh --install-meshtastic --channel beta` optionally configures the
current Meshtastic upstream package channel. It never changes RF region, power,
or PSKs.

## First deployment

```bash
sudo mesh-radio radios
# Choose the displayed selector (USB serial is preferred).
sudo mesh-radio assign openhop --device path:4-2 --profile pinedio
sudo mesh-radio assign meshtastic --device serial:12345678 --profile meshtadpole
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
mesh-radio update                    # official openHop, this project, meshtasticd
```

`mesh-radio update` is the one-command LXC update path. It runs the official
`/root/openhop-repeater/manage.sh upgrade` first, then updates Mesh Radio
Manager and meshtasticd. It does not copy, replace, or patch that openHop
updater. Before and after updating, `mesh-radio verify` reports the exact
upstream branch, commit, and whether `/root/openhop-repeater` is clean.

The final Meshtastic phase shows the installed and candidate meshtasticd versions,
then upgrades meshtasticd automatically after updating the manager. The
meshtasticd upgrade backs up `/etc/meshtasticd/config.yaml` under
`/var/lib/mesh-radio-manager/backups` before calling apt. This is deliberately
separate from the official openHop update command.

To remove only this project:

```bash
sudo ./uninstall.sh
```

This removes manager-owned files/drop-ins and leaves openHop, meshtasticd, and
their configurations in place.

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
YAML, and exposes only the assigned USBFS node when a serial selector cannot
be passed to meshtasticd. This is intentionally not based on startup order.

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
