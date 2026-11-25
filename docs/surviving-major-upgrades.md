# Surviving *major* UniFi OS upgrades

The [Survive firmware updates](../README.md#survive-firmware-updates) section of the
main guide handles point releases. A major UniFi OS release can defeat it, and this
page explains how, and what to do instead.

## What actually happened on a UDM Pro going to UniFi OS 6

This is one console's real failure, not a theory.

After the upgrade the WAN port had link, the cloned MAC was still in place, and the DHCP
client sat in a loop of `broadcasting discover` / `leasefail`. Nothing was
authenticating.

| | after the upgrade |
|---|---|
| `/etc/wpa_supplicant/` (config, certificates, cached `.deb`s) | **survived** |
| `/etc/systemd/system/reinstall-wpa.service` and its enable symlink | **survived** |
| `/data/` | survived |
| `/usr/sbin/wpa_supplicant` | **gone** — `dpkg -l` showed the package as `rc` (removed, config kept) |
| Debian base | moved to **13 (trixie)** |

So the recovery service did exactly what it was built to do. It ran at boot, found no
binary, and called `dpkg -Ri` on the cached packages — which were built for
**bullseye**:

```
wpasupplicant_2.9.0-21_arm64.deb   depends on libssl1.1
```

`libssl1.1` does not exist on trixie. `dpkg` failed, systemd retried ten times and gave
up, and the WAN stayed down. **The cache was the right idea, frozen at the wrong Debian
release.**

Check which base you are on before trusting a cached package:

```bash
> . /etc/os-release; echo "$VERSION_CODENAME"
```

### The second failure, once a matching package is installed

Installing trixie's own `wpasupplicant` (2.10, linked against OpenSSL 3) gets further,
then stops before the TLS handshake:

```
OpenSSL: tls_connection_client_cert - SSL_use_certificate_file failed error:0A00018E:SSL routines::ca md too weak
EAP-TLS: Failed to initialize SSL.
```

OpenSSL 3's default security level refuses the signature digest on the certificates
extracted from the ISP gateway. OpenSSL 1.1.1 accepted it. Add this at the top level of
the config — outside the `network={}` block — and authentication succeeds:

```ini
openssl_ciphers=DEFAULT@SECLEVEL=0
```

This lowers the security level only for this supplicant process, not system-wide.

Note what the log showed before that error: the ISP had already sent
`EAP-Request ... method=13 (TLS)`. If you see that, the cable, VLAN and MAC are all
fine, and the problem is local.

## Don't rely on `/etc` surviving

`/etc` survived this upgrade. That is not a promise — the root filesystem is an overlay
that firmware is entitled to replace. `/data` (or `/mnt/data` on older consoles) is
where the console keeps its own databases, and it is the place built to survive.

The approach below keeps everything authoritative on `/data`, and treats anything in
`/etc` as a copy that gets regenerated.

```
/data/wpa_supplicant/
├── wpa-persist.sh          # the script, kept where it can always be found
├── env                     # IFACE=..., optional MAC_OVERRIDE=...
├── conf/
│   └── wpa_supplicant-wired-<iface>.conf
├── certs/                  # the extracted certificates, mode 600
├── packages/
│   └── <codename>/         # cached .debs, one directory per Debian release
├── bin/
│   ├── wpa_supplicant      # self-contained copy of a known-good binary
│   ├── run.sh              # generated launcher
│   └── watchdog.sh         # generated
└── lib/                    # that binary's shared libraries, minus glibc
```

## The approach

[`scripts/wpa-persist.sh`](../scripts/wpa-persist.sh) implements it.

**1. Four ways to end up with a working binary**, cheapest first:

| order | source | survives a Debian base change? |
|---|---|---|
| 1 | a system `wpa_supplicant`, if one is present | — |
| 2 | cached `.deb`s for the *current* release codename | only if cached after the change |
| 3 | `apt-get install` | only if some WAN is up |
| 4 | the bundled binary + its libraries from `/data` | **yes** |

Option 4 needs no package manager, no dependency resolution and no internet. glibc is
deliberately left out of the bundle: an old binary runs fine against a newer glibc, but
an old glibc beside the system's newer loader does not.

Every time the script finds a working binary, it re-caches packages for the running
release and re-bundles, so the cache follows the console instead of going stale.

**2. The OpenSSL 3 fix is applied automatically.** If the system OpenSSL is 3.x and the
config has no `openssl_ciphers` line, one is added.

**3. One supplicant, not two.** The main guide's `reinstall-wpa.service` and
`wpa_supplicant-wired@<iface>.service` are disabled, and a single
`wpa-persist@<iface>.service` takes over. Two supplicants on one port fight each other.

**4. A watchdog for the half-failure.** Authentication can complete after the DHCP
client has already given up, leaving a link that is up with no address. A timer checks
every two minutes and restarts the supplicant after three consecutive misses — slow
enough not to fight a real ISP outage.

## Install

With the certificates and config already on the console (the main guide's layout, or
`conf/` or `certs/` subdirectories):

```bash
> mkdir -p /data/wpa_supplicant
> cp wpa-persist.sh /data/wpa_supplicant/
> chmod 755 /data/wpa_supplicant/wpa-persist.sh
> IFACE=eth9 /data/wpa_supplicant/wpa-persist.sh install /etc/wpa_supplicant
```

This imports the certificates and config, rewrites the certificate paths in the config
to the persistent copies, caches packages, bundles the binary, adds the OpenSSL 3
setting if needed, retires the old units, registers the boot hook, starts the
supplicant and prints a status summary. Check it any time with:

```bash
> /data/wpa_supplicant/wpa-persist.sh status
```

## The honest limit

There is no hook on these consoles guaranteed to run after an upgrade. The console in
this write-up had a `/data/on_boot.d/` directory but nothing that executes it. So the
script installs a systemd unit in `/etc`, plus `/data/on_boot.d/10-wpa-persist.sh` in
case a runner is present.

If a future release does wipe `/etc`, the unit goes with it. Recovery is then one
command, with no downloads and no certificates to re-extract, because everything it
needs is already on `/data`:

```bash
> /data/wpa_supplicant/wpa-persist.sh boot
```

Keep that line somewhere you can reach from a phone, since the WAN it restores may be
the only one you have.

## Keep a copy off the console

`/data` survives upgrades. It does not survive a factory reset, a storage failure or a
hardware swap. The certificates cannot be recreated without the ISP gateway they came
from — if that hardware has gone back to the ISP, they cannot be recreated at all. Copy
`certs/` and the config somewhere else, mode 600.

## Troubleshooting

Run the supplicant in the foreground to see the handshake:

```bash
> systemctl stop wpa-persist@eth9
> /data/wpa_supplicant/bin/run.sh eth9
```

`CTRL-EVENT-EAP-SUCCESS` followed by `CTRL-EVENT-CONNECTED` means it worked. Restart the
service and leave it alone.

| symptom | cause |
|---|---|
| `reinstall-wpa.service` failed, `dpkg` errors on `wpasupplicant` | cached packages built for an older Debian release; see above |
| `ca md too weak` | OpenSSL 3 security level; add `openssl_ciphers=DEFAULT@SECLEVEL=0` |
| `Failed to load root certificates ... No such file or directory` | certificate paths in the config are not absolute; see [the main guide](../README.md#fopen) |
| link up, no address, no EAP lines in the log at all | no supplicant is running — check `wpa-persist.sh status` |

If you kill a stray supplicant by hand, use `pidof wpa_supplicant` rather than
`pkill -f`. Over SSH, `pkill -f` with a pattern also matches the remote shell running
the command, and kills your own session.
