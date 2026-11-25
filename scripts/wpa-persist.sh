#!/bin/bash
# wpa-persist.sh - keep the AT&T EAP-TLS bypass alive across UniFi OS upgrades.
#
# A major UniFi OS release replaces the whole root filesystem, so anything in
# /etc, /sbin or /lib is gone after it reboots - including the wpasupplicant
# package, the systemd units, and the cached .deb files if they were kept under
# /etc. This script keeps every piece on the persistent data partition instead,
# and re-creates the ephemeral parts on each boot.
#
#   wpa-persist.sh install   first-time setup; imports certs + conf, caches
#                            packages, registers the boot hook, starts auth
#   wpa-persist.sh boot      re-create units and start auth (run at every boot)
#   wpa-persist.sh cache     refresh cached packages + bundled binary
#   wpa-persist.sh status    report what is in place
#
# Configuration lives in <persist>/wpa_supplicant/env - see IFACE / MAC_OVERRIDE.

set -u

# ---------------------------------------------------------------- locations --
# /data on current consoles, /mnt/data on older ones. Both survive upgrades.
PERSIST=""
for candidate in /data /mnt/data; do
    [ -d "$candidate" ] && [ -w "$candidate" ] && PERSIST="$candidate" && break
done
if [ -z "$PERSIST" ]; then
    echo "wpa-persist: no writable persistent partition (/data, /mnt/data)" >&2
    exit 1
fi

ROOT="$PERSIST/wpa_supplicant"
ENV_FILE="$ROOT/env"
CONF_DIR="$ROOT/conf"
CERT_DIR="$ROOT/certs"
PKG_DIR="$ROOT/packages"
BIN_DIR="$ROOT/bin"
LIB_DIR="$ROOT/lib"

IFACE="${IFACE:-eth9}"
MAC_OVERRIDE=""
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

CONF="$CONF_DIR/wpa_supplicant-wired-$IFACE.conf"
CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-unknown}")"

log() { echo "[wpa-persist] $*"; }
die() { echo "[wpa-persist] ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------ the supplicant --
# Four ways to end up with a working binary, cheapest first. The last one is
# what makes this survive a change of Debian base: a copy of the binary and its
# shared libraries, kept on the persistent partition, with no package manager
# and no network involved.
resolve_binary() {
    WPA_BIN="$(command -v wpa_supplicant 2>/dev/null)"
    [ -n "$WPA_BIN" ] && { log "using system binary $WPA_BIN"; return 0; }

    if [ -d "$PKG_DIR/$CODENAME" ] && ls "$PKG_DIR/$CODENAME"/*.deb >/dev/null 2>&1; then
        log "installing cached packages for $CODENAME"
        dpkg -Ri "$PKG_DIR/$CODENAME" >/dev/null 2>&1
        WPA_BIN="$(command -v wpa_supplicant 2>/dev/null)"
        [ -n "$WPA_BIN" ] && return 0
    fi

    if apt-get install -y wpasupplicant >/dev/null 2>&1; then
        log "installed wpasupplicant from the archive"
        WPA_BIN="$(command -v wpa_supplicant 2>/dev/null)"
        [ -n "$WPA_BIN" ] && return 0
    fi

    if [ -x "$BIN_DIR/wpa_supplicant" ]; then
        log "falling back to the bundled binary (no package manager needed)"
        WPA_BIN="$BIN_DIR/wpa_supplicant"
        return 0
    fi

    return 1
}

# Keep a self-contained copy so a future release with a different libc/libssl
# generation still has something to run while apt is unreachable.
bundle_binary() {
    local src="$1"
    case "$src" in "$BIN_DIR"/*) return 0 ;; esac   # already the bundled one

    mkdir -p "$BIN_DIR" "$LIB_DIR"
    cp -f "$src" "$BIN_DIR/wpa_supplicant"
    # glibc itself stays out: an old libc beside the system's newer loader
    # crashes, while an old binary against a newer glibc works fine.
    rm -f "$LIB_DIR"/*
    ldd "$src" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' \
        | grep -vE '/(ld-linux[^/]*|libc|libm|libdl|libpthread|librt|libresolv)\.so' \
        | while read -r lib; do cp -fL "$lib" "$LIB_DIR/" 2>/dev/null; done
    echo "$CODENAME" > "$BIN_DIR/.codename"
    log "bundled $(basename "$src") + $(ls -1 "$LIB_DIR" | wc -l) libraries for $CODENAME"
}

# Cache the .deb files for THIS Debian release, so the next upgrade has
# packages that match. Caching bullseye packages onto a trixie rootfs is the
# failure this whole script exists to prevent.
cache_packages() {
    local dest="$PKG_DIR/$CODENAME"
    mkdir -p "$dest"
    if apt-get install --reinstall --download-only -y wpasupplicant libpcsclite1 >/dev/null 2>&1; then
        cp -f /var/cache/apt/archives/wpasupplicant_*.deb "$dest/" 2>/dev/null
        cp -f /var/cache/apt/archives/libpcsclite1_*.deb "$dest/" 2>/dev/null
        log "cached $(ls -1 "$dest" | wc -l) package(s) for $CODENAME"
    else
        log "could not reach the archive; keeping whatever is already cached"
    fi
}

# OpenSSL 3 rejects the ISP gateway certificates at its default security level
# ("ca md too weak"): the signature digest that 1.1.1 accepted is now refused.
# Lowering the level is scoped to this one supplicant process.
ensure_seclevel() {
    grep -q '^openssl_ciphers=' "$CONF" && return 0
    if openssl version 2>/dev/null | grep -qE '^OpenSSL [3-9]'; then
        sed -i '/^network={/i openssl_ciphers=DEFAULT@SECLEVEL=0' "$CONF"
        log "added openssl_ciphers=DEFAULT@SECLEVEL=0 for OpenSSL 3"
    fi
}

# ------------------------------------------------------------------- runtime --
write_runner() {
    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/run.sh" <<RUNNER
#!/bin/bash
# Generated by wpa-persist.sh - picks the system binary, else the bundled copy.
IFACE="\$1"
ROOT="$ROOT"
CONF="\$ROOT/conf/wpa_supplicant-wired-\$IFACE.conf"
BIN="\$(command -v wpa_supplicant 2>/dev/null)"
if [ -z "\$BIN" ] && [ -x "\$ROOT/bin/wpa_supplicant" ]; then
    BIN="\$ROOT/bin/wpa_supplicant"
    export LD_LIBRARY_PATH="\$ROOT/lib:\${LD_LIBRARY_PATH:-}"
fi
[ -n "\$BIN" ] || { echo "no wpa_supplicant available" >&2; exit 1; }
exec "\$BIN" -i "\$IFACE" -D wired -c "\$CONF"
RUNNER
    chmod 755 "$BIN_DIR/run.sh"
}

# The units are written to /etc on every boot because /etc does not survive a
# major upgrade. Nothing here reads state from /etc - it is all generated.
write_units() {
    cat > /etc/systemd/system/wpa-persist@.service <<UNIT
[Unit]
Description=EAP-TLS supplicant on %I (ISP gateway bypass)
After=network.target
Wants=network.target
StartLimitIntervalSec=0

[Service]
ExecStart=$BIN_DIR/run.sh %I
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/wpa-persist-watchdog.service <<UNIT
[Unit]
Description=Restart EAP-TLS supplicant when the WAN has no lease

[Service]
Type=oneshot
ExecStart=$BIN_DIR/watchdog.sh
UNIT

    cat > /etc/systemd/system/wpa-persist-watchdog.timer <<UNIT
[Unit]
Description=Check the EAP-TLS WAN every two minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
UNIT

    # Authentication can succeed while the DHCP client has already given up, so
    # the symptom is a link that is up with no address. Three strikes, then
    # restart - slow enough not to fight a genuine ISP outage.
    cat > "$BIN_DIR/watchdog.sh" <<WATCHDOG
#!/bin/bash
IFACE="$IFACE"
STATE="$ROOT/.watchdog-misses"
if ip -4 addr show dev "\$IFACE" 2>/dev/null | grep -q 'inet '; then
    echo 0 > "\$STATE"
    exit 0
fi
MISSES=\$(( \$(cat "\$STATE" 2>/dev/null || echo 0) + 1 ))
echo "\$MISSES" > "\$STATE"
if [ "\$MISSES" -ge 3 ]; then
    logger -t wpa-persist "no IPv4 on \$IFACE after \$MISSES checks; restarting supplicant"
    systemctl restart "wpa-persist@\$IFACE.service"
    echo 0 > "\$STATE"
fi
WATCHDOG
    chmod 755 "$BIN_DIR/watchdog.sh"

    # Optional: only needed if the controller's own MAC-clone setting is not
    # used. Controller-side cloning is stored in the controller database and
    # already survives upgrades, so prefer it.
    if [ -n "$MAC_OVERRIDE" ]; then
        mkdir -p /etc/network/if-up.d
        cat > /etc/network/if-up.d/changemac <<MACHOOK
#!/bin/sh
if [ "\$IFACE" = $IFACE ]; then
  ip link set dev "\$IFACE" address $MAC_OVERRIDE
fi
MACHOOK
        chmod 755 /etc/network/if-up.d/changemac
        ip link set dev "$IFACE" address "$MAC_OVERRIDE" 2>/dev/null
    fi

    # Compatibility shim for anyone used to the packaged unit's paths.
    mkdir -p /etc/wpa_supplicant
    ln -sfn "$CONF" "/etc/wpa_supplicant/wpa_supplicant-wired-$IFACE.conf"
    ln -sfn "$CERT_DIR" /etc/wpa_supplicant/certs

    systemctl daemon-reload
}

# The main guide's units would start a second supplicant on the same port.
retire_legacy_units() {
    local unit
    for unit in reinstall-wpa.service "wpa_supplicant-wired@$IFACE.service"; do
        if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
            systemctl disable --now "$unit" >/dev/null 2>&1
            log "retired $unit"
        fi
    done
}

# --------------------------------------------------------------- boot hook --
# Best case the console runs <persist>/on_boot.d natively. Otherwise we drop a
# unit into /etc, which works until the next MAJOR upgrade wipes it - at which
# point one command re-arms everything, with no downloads and no certificates
# to re-extract, because all the state is already on the persistent partition.
register_boot_hook() {
    local hook_dir="$PERSIST/on_boot.d"
    mkdir -p "$hook_dir"
    cat > "$hook_dir/10-wpa-persist.sh" <<HOOK
#!/bin/sh
$ROOT/wpa-persist.sh boot
HOOK
    chmod 755 "$hook_dir/10-wpa-persist.sh"

    if systemctl list-unit-files 2>/dev/null | grep -qiE 'udm-boot|on-?boot'; then
        log "boot hook installed at $hook_dir/10-wpa-persist.sh (an on_boot runner is present)"
        BOOT_HOOK_NATIVE=yes
    else
        log "no on_boot.d runner found; installing a systemd unit as well"
        cat > /etc/systemd/system/wpa-persist-boot.service <<UNIT
[Unit]
Description=Re-arm the EAP-TLS bypass after boot
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$ROOT/wpa-persist.sh boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable wpa-persist-boot.service >/dev/null 2>&1
        BOOT_HOOK_NATIVE=no
    fi
}

# ------------------------------------------------------------------ actions --
do_boot() {
    [ -f "$CONF" ] || die "no config at $CONF - run 'install' first"
    resolve_binary || die "no wpa_supplicant available by any route"
    bundle_binary "$WPA_BIN"
    ensure_seclevel
    write_runner
    write_units
    retire_legacy_units
    systemctl enable --now "wpa-persist@$IFACE.service" >/dev/null 2>&1
    systemctl enable --now wpa-persist-watchdog.timer >/dev/null 2>&1
    log "supplicant armed on $IFACE"
}

do_install() {
    local src="${1:-/etc/wpa_supplicant}"
    mkdir -p "$CONF_DIR" "$CERT_DIR" "$PKG_DIR" "$BIN_DIR" "$LIB_DIR"
    chmod 700 "$CERT_DIR"

    # Import certificates and config from wherever they are today, and rewrite
    # the certificate paths to point at the persistent copies.
    local dir
    for dir in "$src" "$src/certs" "$src/conf"; do
        cp -f "$dir"/*.pem "$CERT_DIR/" 2>/dev/null
    done
    chmod 600 "$CERT_DIR"/*.pem 2>/dev/null
    log "imported $(ls -1 "$CERT_DIR" | wc -l) certificate file(s)"

    # First match wins, in this order. (Not `ls a b c | head -1`: ls re-sorts
    # its arguments alphabetically and the priority is lost.)
    local found="" candidate
    for candidate in "$src/wpa_supplicant-wired-$IFACE.conf" "$src"/wpa_supplicant*.conf "$src"/conf/wpa_supplicant*.conf; do
        [ -f "$candidate" ] && { found="$candidate"; break; }
    done
    if [ -n "$found" ] && [ ! -f "$CONF" ]; then
        sed -E "s#^([[:space:]]*(ca_cert|client_cert|private_key)=\")[^\"]*/([^\"/]+)\"#\1$CERT_DIR/\3\"#" "$found" > "$CONF"
        chmod 600 "$CONF"
        log "imported config from $found"
    fi
    [ -f "$CONF" ] || die "no config found; put one at $CONF"

    [ -f "$ENV_FILE" ] || printf 'IFACE=%s\nMAC_OVERRIDE=%s\n' "$IFACE" "$MAC_OVERRIDE" > "$ENV_FILE"
    cp -f "$0" "$ROOT/wpa-persist.sh" 2>/dev/null; chmod 755 "$ROOT/wpa-persist.sh"

    cache_packages
    register_boot_hook
    do_boot
    do_status
}

do_status() {
    echo "persistent root : $ROOT"
    echo "debian codename : $CODENAME"
    echo "interface       : $IFACE"
    echo "config          : $([ -f "$CONF" ] && echo present || echo MISSING)"
    echo "certificates    : $(ls -1 "$CERT_DIR" 2>/dev/null | wc -l) file(s)"
    echo "cached packages : $(ls -1 "$PKG_DIR/$CODENAME" 2>/dev/null | wc -l) for $CODENAME"
    echo "bundled binary  : $([ -x "$BIN_DIR/wpa_supplicant" ] && echo "yes (built for $(cat "$BIN_DIR/.codename" 2>/dev/null))" || echo no)"
    echo "system binary   : $(command -v wpa_supplicant 2>/dev/null || echo absent)"
    echo "service         : $(systemctl is-active "wpa-persist@$IFACE.service" 2>/dev/null)"
    echo "watchdog        : $(systemctl is-active wpa-persist-watchdog.timer 2>/dev/null)"
    echo "address on $IFACE : $(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2}' || echo none)"
}

case "${1:-status}" in
    install) shift; do_install "${1:-/etc/wpa_supplicant}" ;;
    boot)    do_boot ;;
    cache)   cache_packages; resolve_binary && bundle_binary "$WPA_BIN" ;;
    status)  do_status ;;
    *)       echo "usage: $0 {install [source-dir]|boot|cache|status}" >&2; exit 2 ;;
esac
