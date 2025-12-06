#!/bin/sh
# Universal VLESS+XRay+dnsmasq/ipset setup for Keenetic (Entware)
# One-button style: backup, generate, test, rollback on failure.

###############################################################################
# Constants and paths
###############################################################################

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

VLESS_CONF="$BASE_DIR/vless.conf"
DNS_LIST="$BASE_DIR/dns.list"
IP_CONF="$BASE_DIR/ip.conf"

XRAY_BIN="/opt/sbin/xray"
XRAY_CONF_DIR="/opt/etc/xray/configs"

DNSMASQ_CONF="/opt/etc/dnsmasq.conf"

NDM_NETFILTER_DIR="/opt/etc/ndm/netfilter.d"
REDIRECT_SCRIPT="$NDM_NETFILTER_DIR/100-redirect.sh"

INIT_DIR="/opt/etc/init.d"
INIT_XRAY="$INIT_DIR/S24xray"
INIT_DNSMASQ="$INIT_DIR/S56dnsmasq"
INIT_UNBLOCK="$INIT_DIR/S99unblock"

UNBLOCK_DNSMASQ="/opt/etc/unblock.dnsmasq"
UNBLOCK_TXT="/opt/etc/unblock.txt"
UNBLOCK_UPDATE="/opt/bin/unblock_update.sh"
UNBLOCK_DNSMASQ_SH="/opt/bin/unblock_dnsmasq.sh"
UNBLOCK_IPSET_SH="/opt/bin/unblock_ipset.sh"

BACKUP_ROOT="/opt/vless_autosetup_backup_$(date +%Y%m%d-%H%M%S)"
TOUCHED_FILES=""

# Directory where we keep copies of generated configs for inspection
GEN_DIR="$BASE_DIR/gen"

###############################################################################
# Logging, backup and gen-copy helpers
###############################################################################

log() { echo "[*] $*"; }
log_ok() { echo "[OK] $*"; }
log_err() { echo "[ERR] $*" >&2; }

backup_file() {
    local dst="$1"
    [ -z "$dst" ] && return 0

    # Already backed up?
    echo "$TOUCHED_FILES" | grep -q " $dst " && return 0

    if [ -f "$dst" ]; then
        local bkp="$BACKUP_ROOT$dst"
        mkdir -p "$(dirname "$bkp")" 2>/dev/null || {
            log_err "Failed to create backup directory for $dst"
            return 1
        }
        cp "$dst" "$bkp" || {
            log_err "Failed to backup $dst to $bkp"
            return 1
        }
        log "Backup: $dst -> $bkp"
    else
        # File did not exist before; we will remove it on rollback
        log "Marking $dst as newly created (will be removed on rollback)"
    fi

    TOUCHED_FILES="$TOUCHED_FILES $dst "
    return 0
}

restore_all() {
    [ -z "$TOUCHED_FILES" ] && return 0
    log "Restoring previous files from backup..."
    for f in $TOUCHED_FILES; do
        local bkp="$BACKUP_ROOT$f"
        if [ -f "$bkp" ]; then
            cp "$bkp" "$f" && log "Restored $f"
        else
            rm -f "$f"
            log "Removed newly created $f"
        fi
    done
    log "Restore complete."
}

fail() {
    log_err "$*"
    restore_all
    exit 1
}

trap 'log_err "Interrupted"; restore_all; exit 1' INT TERM

copy_to_gen() {
    # copy_to_gen <src> <relative_path_inside_gen>
    local src="$1"
    local rel="$2"

    [ -f "$src" ] || return 0

    local dst="$GEN_DIR/$rel"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || {
        log_err "Failed to create gen directory for $dst"
        return 0
    }
    cp "$src" "$dst" || log_err "Failed to copy $src to $dst"
}

###############################################################################
# (1) Cleanup of old/unused packages (shadowsocks-libev)
###############################################################################

clean_old_packages() {
    log "Cleaning old/unnecessary packages (shadowsocks-libev)..."
    OLD_PKGS="
shadowsocks-libev-config
shadowsocks-libev-ss-local
shadowsocks-libev-ss-redir
shadowsocks-libev-ss-tunnel
"
    for p in $OLD_PKGS; do
        if opkg list-installed 2>/dev/null | awk '{print $1}' | grep -qx "$p"; then
            log "Removing package: $p"
            opkg remove "$p" || fail "Failed to remove $p"
        fi
    done
    log_ok "Old packages cleanup done."
}

###############################################################################
# (2) Install required packages (one-by-one)
###############################################################################

ensure_pkg() {
    local pkg="$1"
    if opkg list-installed 2>/dev/null | awk '{print $1}' | grep -qx "$pkg"; then
        log_ok "Package already installed: $pkg"
    else
        log "Installing package: $pkg"
        opkg install "$pkg" || fail "Failed to install $pkg"
        log_ok "Installed: $pkg"
    fi
}

install_required_packages() {
    log "Updating opkg package lists..."
    opkg update || fail "opkg update failed"

    # Minimal set for this scheme
    PKGS="
xray-core
dnsmasq-full
bind-dig
"
    for p in $PKGS; do
        ensure_pkg "$p"
    done

    log_ok "All required packages are installed."
    # Intentionally do NOT remove opkg cache.
}

###############################################################################
# (3) Parse VLESS URL from vless.conf
###############################################################################

urldecode_simple() {
    # Simple URL decoder: only handles %2F -> /
    echo "$1" | sed 's/%2[Ff]/\//g'
}

parse_vless_conf() {
    [ -f "$VLESS_CONF" ] || fail "vless.conf not found at $VLESS_CONF"

    VLESS_URL="$(grep -m1 '^vless://' "$VLESS_CONF" | tr -d '\r\n')"
    [ -n "$VLESS_URL" ] || fail "vless.conf does not contain a vless:// URL"

    # Remove scheme
    local no_scheme="${VLESS_URL#vless://}"

    # Extract tag (fragment after #), if present
    if echo "$no_scheme" | grep -q '#'; then
        VLESS_TAG="${no_scheme#*#}"
        no_scheme="${no_scheme%%#*}"
    else
        VLESS_TAG="vless-out"
    fi

    # Split into base and query part
    local base query
    case "$no_scheme" in
        *\?*)
            base="${no_scheme%%\?*}"
            query="${no_scheme#*\?}"
            ;;
        *)
            base="$no_scheme"
            query=""
            ;;
    esac

    # base = UUID@host:port
    VLESS_UUID="${base%@*}"
    local hostport="${base#*@}"
    VLESS_HOST="${hostport%%:*}"
    VLESS_PORT="${hostport##*:}"

    # Helper for extracting query parameters
    get_q_param() {
        local key="$1"
        printf '%s\n' "$query" | tr '&' '\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
    }

    VLESS_TYPE="$(get_q_param type)"
    VLESS_ENC="$(get_q_param encryption)"
    VLESS_PATH_RAW="$(get_q_param path)"
    VLESS_HOSTHDR="$(get_q_param host)"
    VLESS_MODE="$(get_q_param mode)"
    VLESS_SEC="$(get_q_param security)"
    VLESS_PBK="$(get_q_param pbk)"
    VLESS_FP="$(get_q_param fp)"
    VLESS_SNI="$(get_q_param sni)"
    VLESS_SID="$(get_q_param sid)"
    VLESS_SPX_RAW="$(get_q_param spx)"

    VLESS_PATH="$(urldecode_simple "$VLESS_PATH_RAW")"
    VLESS_SPX="$(urldecode_simple "$VLESS_SPX_RAW")"

    [ -z "$VLESS_TYPE" ] && VLESS_TYPE="tcp"
    [ -z "$VLESS_ENC" ] && VLESS_ENC="none"

    log_ok "Parsed VLESS:"
    log "  TAG         = $VLESS_TAG"
    log "  UUID        = $VLESS_UUID"
    log "  HOST        = $VLESS_HOST"
    log "  PORT        = $VLESS_PORT"
    log "  TYPE        = $VLESS_TYPE"
    log "  ENC         = $VLESS_ENC"
    log "  PATH        = $VLESS_PATH"
    log "  HOST HEADER = $VLESS_HOSTHDR"
    log "  MODE        = $VLESS_MODE"
    log "  SECURITY    = $VLESS_SEC"
    log "  PBK         = $VLESS_PBK"
    log "  FP          = $VLESS_FP"
    log "  SNI         = $VLESS_SNI"
    log "  SID         = $VLESS_SID"
    log "  SPX         = $VLESS_SPX"
}

###############################################################################
# (5) Detect router IP (from ip.conf or auto)
###############################################################################

detect_router_ip() {
    # 1) Try to read IP from ip.conf and verify that it is actually assigned
    if [ -f "$IP_CONF" ]; then
        local file_ip
        file_ip="$(grep -m1 -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$IP_CONF" 2>/dev/null)"
        if [ -n "$file_ip" ]; then
            # Check that this IP exists on some interface (inet <ip>/...)
            if ip addr show 2>/dev/null | grep -q "inet $file_ip/"; then
                ROUTER_IP="$file_ip"
                log_ok "Router IP from ip.conf: $ROUTER_IP"
                return 0
            else
                log_err "IP from ip.conf ($file_ip) is not configured on any interface, falling back to auto-detect."
            fi
        fi
    fi

    # 2) Auto-detect from br0
    ROUTER_IP="$(ip addr show br0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
    if [ -z "$ROUTER_IP" ] && command -v ifconfig >/dev/null 2>&1; then
        ROUTER_IP="$(ifconfig br0 2>/dev/null | awk '/inet addr:/ {sub("addr:","",$2); print $2}' | head -n1)"
    fi

    [ -n "$ROUTER_IP" ] || fail "Failed to detect router IP (br0). Create ip.conf with a valid LAN IP."

    log_ok "Detected router IP: $ROUTER_IP"
}

###############################################################################
# (4) Load DNS list (dns.list) – avoid router IP as upstream
###############################################################################

load_dns_list() {
    [ -f "$DNS_LIST" ] || fail "dns.list not found at $DNS_LIST"

    local raw d
    raw="$(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$DNS_LIST" | tr -d '\r' | sed '/^$/d')"

    DNS_SERVERS=""
    for d in $raw; do
        # Avoid using router IP as upstream DNS to prevent recursion
        if [ -n "$ROUTER_IP" ] && [ "$d" = "$ROUTER_IP" ]; then
            log "Skipping DNS server equal to router IP ($d) to avoid recursion"
            continue
        fi
        DNS_SERVERS="$DNS_SERVERS $d"
    done

    DNS_SERVERS="$(echo "$DNS_SERVERS" | sed 's/^ *//')"

    [ -n "$DNS_SERVERS" ] || fail "dns.list does not contain valid external IPv4 DNS servers"

    log_ok "Loaded DNS servers from dns.list:"
    echo "$DNS_SERVERS" | tr ' ' '\n' | sed 's/^/   - /' | sed '/^   -$/d'
}

###############################################################################
# (6–7) Generate configs and scripts and place them in correct locations
#       Also copy generated files into $GEN_DIR for inspection
###############################################################################

generate_xray_configs() {
    mkdir -p "$XRAY_CONF_DIR" || fail "Cannot create $XRAY_CONF_DIR"

    local f

    # 01_log.json
    f="$XRAY_CONF_DIR/01_log.json"
    backup_file "$f" || fail "Backup failed for $f"
    cat > "$f" <<'EOF'
{
  "log": {
    "access": "none",
    "error": "/tmp/xray/error.log",
    "loglevel": "error",
    "dnsLog": false
  }
}
EOF
    log_ok "Written $f"
    copy_to_gen "$f" "xray/01_log.json"

    # 03_inbounds.json
    f="$XRAY_CONF_DIR/03_inbounds.json"
    backup_file "$f" || fail "Backup failed for $f"
    cat > "$f" <<'EOF'
{
  "inbounds": [
    {
      "tag": "redirect",
      "listen": "0.0.0.0",
      "port": 61219,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ]
}
EOF
    log_ok "Written $f"
    copy_to_gen "$f" "xray/03_inbounds.json"

    # 04_outbounds.json — based on vless.conf
    f="$XRAY_CONF_DIR/04_outbounds.json"
    backup_file "$f" || fail "Backup failed for $f"
    cat > "$f" <<EOF
{
  "outbounds": [
    {
      "tag": "$VLESS_TAG",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$VLESS_HOST",
            "port": $VLESS_PORT,
            "users": [
              {
                "id": "$VLESS_UUID",
                "encryption": "$VLESS_ENC"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$VLESS_TYPE",
        "xhttpSettings": {
          "path": "$VLESS_PATH",
          "host": "$VLESS_HOSTHDR",
          "mode": "$VLESS_MODE"
        },
        "security": "$VLESS_SEC",
        "realitySettings": {
          "publicKey": "$VLESS_PBK",
          "fingerprint": "$VLESS_FP",
          "serverName": "$VLESS_SNI",
          "shortId": "$VLESS_SID",
          "spiderX": "$VLESS_SPX"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
    log_ok "Written $f"
    copy_to_gen "$f" "xray/04_outbounds.json"

    # 05_routing.json — everything from inbound "redirect" goes to VLESS_TAG
    f="$XRAY_CONF_DIR/05_routing.json"
    backup_file "$f" || fail "Backup failed for $f"
    cat > "$f" <<EOF
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "redirect"
        ],
        "outboundTag": "$VLESS_TAG"
      }
    ]
  }
}
EOF
    log_ok "Written $f"
    copy_to_gen "$f" "xray/05_routing.json"

    # 06_policy.json
    f="$XRAY_CONF_DIR/06_policy.json"
    backup_file "$f" || fail "Backup failed for $f"
    cat > "$f" <<'EOF'
{
  "policy": {
    "levels": {
      "0": {
        "connIdle": 30
      }
    }
  }
}
EOF
    log_ok "Written $f"
    copy_to_gen "$f" "xray/06_policy.json"
}

generate_dnsmasq_conf() {
    mkdir -p "$(dirname "$DNSMASQ_CONF")" || fail "Cannot create $(dirname "$DNSMASQ_CONF")"
    backup_file "$DNSMASQ_CONF" || fail "Backup failed for $DNSMASQ_CONF"

    {
        echo "user=nobody"
        echo "bogus-priv"
        echo "no-negcache"
        echo "clear-on-reload"
        echo "bind-dynamic"
        echo "listen-address=$ROUTER_IP"
        echo "listen-address=127.0.0.1"
        echo "min-port=4096"
        echo "cache-size=1536"
        echo "expand-hosts"
        echo "log-async"
        echo "conf-file=$UNBLOCK_DNSMASQ"
        echo
        for d in $DNS_SERVERS; do
            echo "server=$d"
        done
    } > "$DNSMASQ_CONF"

    log_ok "Written $DNSMASQ_CONF"
    copy_to_gen "$DNSMASQ_CONF" "dnsmasq.conf"
}

ensure_unblock_dnsmasq() {
    # Make sure directory exists
    mkdir -p "$(dirname "$UNBLOCK_DNSMASQ")" || fail "Cannot create directory for $UNBLOCK_DNSMASQ"

    # Backup existing file (or mark as newly created)
    backup_file "$UNBLOCK_DNSMASQ" || fail "Backup failed for $UNBLOCK_DNSMASQ"

    if [ -x "$UNBLOCK_DNSMASQ_SH" ]; then
        log "Generating $UNBLOCK_DNSMASQ using $UNBLOCK_DNSMASQ_SH..."
        "$UNBLOCK_DNSMASQ_SH" || fail "unblock_dnsmasq.sh failed"
    else
        if [ ! -f "$UNBLOCK_DNSMASQ" ]; then
            log "Creating empty $UNBLOCK_DNSMASQ (no unblock rules yet)..."
            : > "$UNBLOCK_DNSMASQ" || fail "Cannot create $UNBLOCK_DNSMASQ"
        else
            log_ok "$UNBLOCK_DNSMASQ already exists."
        fi
    fi

    copy_to_gen "$UNBLOCK_DNSMASQ" "unblock.dnsmasq"
}

generate_redirect_script() {
    mkdir -p "$NDM_NETFILTER_DIR" || fail "Cannot create $NDM_NETFILTER_DIR"
    backup_file "$REDIRECT_SCRIPT" || fail "Backup failed for $REDIRECT_SCRIPT"

    cat > "$REDIRECT_SCRIPT" <<EOF
#!/bin/sh
[ "\$type" = "ip6tables" ] && exit 0

if [ -z "\$(iptables-save 2>/dev/null | grep 'unblock')" ]; then
    ipset create unblock hash:net -exist
    iptables -I PREROUTING -w -t nat -i br0 -p tcp -m set --match-set unblock dst -j REDIRECT --to-port 61219
    iptables -I PREROUTING -w -t nat -i br0 -p udp -m set --match-set unblock dst -j REDIRECT --to-port 61219
fi
if [ -z "\$(iptables-save 2>/dev/null | grep 'udp --dport 53 -j DNAT')" ]; then
    iptables -w -t nat -I PREROUTING -i br0 -p udp --dport 53 -j DNAT --to $ROUTER_IP
fi
if [ -z "\$(iptables-save 2>/dev/null | grep 'tcp --dport 53 -j DNAT')" ]; then
    iptables -w -t nat -I PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to $ROUTER_IP
fi
exit 0
EOF
    chmod +x "$REDIRECT_SCRIPT"
    log_ok "Written $REDIRECT_SCRIPT"
    copy_to_gen "$REDIRECT_SCRIPT" "netfilter/100-redirect.sh"
}

generate_init_scripts() {
    mkdir -p "$INIT_DIR" || fail "Cannot create $INIT_DIR"

    # S24xray
    backup_file "$INIT_XRAY" || fail "Backup failed for $INIT_XRAY"
    cat > "$INIT_XRAY" <<'EOF'
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -confdir /opt/etc/xray/configs"
PREARGS=""
DESC=$PROCS
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ -z "$(which $PROCS)" ] && exit 0

# Ensure RAM log directory exists
[ -d /tmp/xray ] || mkdir -p /tmp/xray

. /opt/etc/init.d/rc.func
EOF
    chmod +x "$INIT_XRAY"
    log_ok "Written $INIT_XRAY"
    copy_to_gen "$INIT_XRAY" "init.d/S24xray"

    # S56dnsmasq
    backup_file "$INIT_DNSMASQ" || fail "Backup failed for $INIT_DNSMASQ"
    cat > "$INIT_DNSMASQ" <<'EOF'
#!/bin/sh

ENABLED=yes
PROCS=dnsmasq
ARGS="-C /opt/etc/dnsmasq.conf"
PREARGS=""
DESC=$PROCS
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ -z "$(which $PROCS)" ] && exit 0

. /opt/etc/init.d/rc.func
EOF
    chmod +x "$INIT_DNSMASQ"
    log_ok "Written $INIT_DNSMASQ"
    copy_to_gen "$INIT_DNSMASQ" "init.d/S56dnsmasq"

    # S99unblock
    backup_file "$INIT_UNBLOCK" || fail "Backup failed for $INIT_UNBLOCK"
    cat > "$INIT_UNBLOCK" <<'EOF'
#!/bin/sh
[ "$1" != "start" ] && exit 0
/opt/bin/unblock_ipset.sh &
EOF
    chmod +x "$INIT_UNBLOCK"
    log_ok "Written $INIT_UNBLOCK"
    copy_to_gen "$INIT_UNBLOCK" "init.d/S99unblock"
}

###############################################################################
# (8) Checks: XRay config & basic DNS
###############################################################################

run_checks() {
    # XRay config test
    log "Testing XRay config..."

    # For the test run, the init script S24xray is not used,
    # so we must ensure that the log directory exists.
    [ -d /tmp/xray ] || mkdir -p /tmp/xray

    "$XRAY_BIN" run -test -confdir "$XRAY_CONF_DIR"
    [ $? -eq 0 ] || fail "XRay config test failed"

    log_ok "XRay config OK."

    # Optional DNS check. It depends on external connectivity,
    # so it is non-fatal and only prints a warning on failure.
    if command -v nslookup >/dev/null 2>&1; then
        log "Testing DNS via dnsmasq ($ROUTER_IP)..."
        if nslookup google.com "$ROUTER_IP" >/tmp/vless_autosetup_nslookup.log 2>&1; then
            log_ok "DNS nslookup succeeded."
        else
            log_err "DNS nslookup failed (see /tmp/vless_autosetup_nslookup.log)."
        fi
    fi
}

###############################################################################
# (9) Restart services
###############################################################################

restart_services() {
    log "Restarting dnsmasq..."
    "$INIT_DNSMASQ" restart || fail "Failed to restart dnsmasq"

    log "Restarting XRay..."
    "$INIT_XRAY" restart || fail "Failed to restart XRay"

    # Update ipset (if helper scripts exist)
    if [ -x "$UNBLOCK_UPDATE" ]; then
        log "Running unblock_update.sh..."
        "$UNBLOCK_UPDATE"
    elif [ -x "$UNBLOCK_IPSET_SH" ]; then
        log "Running unblock_ipset.sh..."
        "$UNBLOCK_IPSET_SH" &
    fi

    log_ok "Services restarted."
}

###############################################################################
# MAIN
###############################################################################

log "=== VLESS/XRay autosetup starting ==="

[ -x "$XRAY_BIN" ] || log "Note: xray binary not found yet, will be installed by opkg."

clean_old_packages
install_required_packages
parse_vless_conf
detect_router_ip
load_dns_list

generate_xray_configs
generate_dnsmasq_conf
ensure_unblock_dnsmasq
generate_redirect_script
generate_init_scripts

log_ok "Copies of generated configs are available under: $GEN_DIR"

run_checks
restart_services

log_ok "=== VLESS/XRay autosetup completed successfully ==="
log "Backup of previous config files stored at: $BACKUP_ROOT"

exit 0

