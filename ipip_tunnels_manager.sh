#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/ipip-manager/tunnels"
INSTALL_PATH="/usr/local/sbin/ipip-manager"
SERVICE_FILE="/etc/systemd/system/ipip-manager.service"
MODULE_FILE="/etc/modules-load.d/ipip.conf"

die() {
    echo "Error: $*" >&2
    exit 1
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "Please run with sudo/root."
}

valid_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9._-]{1,15}$ ]] || \
        die "Invalid tunnel name. Use 1-15 characters: letters, numbers, ., _, -"
}

config_file() {
    echo "${CONFIG_DIR}/$1.conf"
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
}

load_config() {
    local name="$1"
    local file
    file="$(config_file "$name")"

    [[ -f "$file" ]] || die "Tunnel '$name' does not exist."

    # shellcheck disable=SC1090
    source "$file"

    : "${NAME:?}"
    : "${LOCAL_PUBLIC:?}"
    : "${REMOTE_PUBLIC:?}"
    : "${LOCAL_CIDR:?}"
    : "${REMOTE_TUN_IP:?}"
    : "${MTU:?}"
    : "${ENABLED:?}"
}

save_config() {
    local name="$1"
    local local_public="$2"
    local remote_public="$3"
    local_cidr="$4"
    local remote_tun_ip="$5"
    local mtu="$6"
    local enabled="${7:-yes}"

    ensure_dirs

    local file
    file="$(config_file "$name")"

    {
        printf 'NAME=%q\n' "$name"
        printf 'LOCAL_PUBLIC=%q\n' "$local_public"
        printf 'REMOTE_PUBLIC=%q\n' "$remote_public"
        printf 'LOCAL_CIDR=%q\n' "$local_cidr"
        printf 'REMOTE_TUN_IP=%q\n' "$remote_tun_ip"
        printf 'MTU=%q\n' "$mtu"
        printf 'ENABLED=%q\n' "$enabled"
    } > "$file"

    chmod 600 "$file"
}

runtime_delete() {
    local name="$1"

    if ip link show "$name" >/dev/null 2>&1; then
        ip link set "$name" down 2>/dev/null || true
        ip tunnel del "$name" 2>/dev/null || ip link del "$name" 2>/dev/null || true
    fi
}

tunnel_up() {
    local name="$1"
    valid_name "$name"
    load_config "$name"

    modprobe ipip

    if [[ "$ENABLED" != "yes" ]]; then
        echo "$name is disabled. Use: ipip-manager enable $name"
        return 0
    fi

    # Recreate to guarantee the saved configuration is applied.
    runtime_delete "$NAME"

    ip tunnel add "$NAME" \
        mode ipip \
        local "$LOCAL_PUBLIC" \
        remote "$REMOTE_PUBLIC" \
        ttl 255

    ip addr add "$LOCAL_CIDR" dev "$NAME"
    ip link set "$NAME" mtu "$MTU"
    ip link set "$NAME" up

    echo "UP: $NAME"
    echo "  Public: $LOCAL_PUBLIC -> $REMOTE_PUBLIC"
    echo "  Tunnel: $LOCAL_CIDR -> $REMOTE_TUN_IP"
    echo "  MTU:    $MTU"
}

tunnel_down() {
    local name="$1"
    valid_name "$name"
    load_config "$name"
    runtime_delete "$name"
    echo "DOWN: $name"
}

cmd_add() {
    [[ $# -ge 5 && $# -le 6 ]] || {
        usage
        exit 1
    }

    local name="$1"
    local local_public="$2"
    local remote_public="$3"
    local local_cidr="$4"
    local remote_tun_ip="$5"
    local mtu="${6:-1480}"

    valid_name "$name"

    [[ "$mtu" =~ ^[0-9]+$ ]] || die "MTU must be a number."
    (( mtu >= 576 && mtu <= 65535 )) || die "MTU looks invalid."

    local file
    file="$(config_file "$name")"
    [[ ! -f "$file" ]] || die "Tunnel '$name' already exists. Delete it first or use 'edit'."

    save_config \
        "$name" \
        "$local_public" \
        "$remote_public" \
        "$local_cidr" \
        "$remote_tun_ip" \
        "$mtu" \
        "yes"

    tunnel_up "$name"

    echo
    echo "Saved persistently in: $file"
}

cmd_edit() {
    [[ $# -ge 5 && $# -le 6 ]] || {
        usage
        exit 1
    }

    local name="$1"
    local local_public="$2"
    local remote_public="$3"
    local local_cidr="$4"
    local remote_tun_ip="$5"
    local mtu="${6:-1480}"

    valid_name "$name"
    [[ -f "$(config_file "$name")" ]] || die "Tunnel '$name' does not exist."

    local old_enabled="yes"
    load_config "$name"
    old_enabled="$ENABLED"

    save_config \
        "$name" \
        "$local_public" \
        "$remote_public" \
        "$local_cidr" \
        "$remote_tun_ip" \
        "$mtu" \
        "$old_enabled"

    if [[ "$old_enabled" == "yes" ]]; then
        tunnel_up "$name"
    fi

    echo "Updated: $name"
}

cmd_delete() {
    [[ $# -eq 1 ]] || die "Usage: ipip-manager delete <name>"

    local name="$1"
    valid_name "$name"

    local file
    file="$(config_file "$name")"
    [[ -f "$file" ]] || die "Tunnel '$name' does not exist."

    runtime_delete "$name"
    rm -f "$file"

    echo "Deleted: $name"
}

cmd_enable_tunnel() {
    [[ $# -eq 1 ]] || die "Usage: ipip-manager enable <name>"

    local name="$1"
    load_config "$name"

    save_config \
        "$NAME" \
        "$LOCAL_PUBLIC" \
        "$REMOTE_PUBLIC" \
        "$LOCAL_CIDR" \
        "$REMOTE_TUN_IP" \
        "$MTU" \
        "yes"

    tunnel_up "$name"
}

cmd_disable_tunnel() {
    [[ $# -eq 1 ]] || die "Usage: ipip-manager disable <name>"

    local name="$1"
    load_config "$name"

    save_config \
        "$NAME" \
        "$LOCAL_PUBLIC" \
        "$REMOTE_PUBLIC" \
        "$LOCAL_CIDR" \
        "$REMOTE_TUN_IP" \
        "$MTU" \
        "no"

    runtime_delete "$name"
    echo "Disabled: $name"
}

cmd_list() {
    ensure_dirs

    printf "%-15s %-8s %-15s %-15s %-18s %-15s %-5s\n" \
        "NAME" "STATE" "LOCAL-PUBLIC" "REMOTE-PUBLIC" "LOCAL-TUNNEL" "REMOTE-TUN" "MTU"

    shopt -s nullglob
    local files=("$CONFIG_DIR"/*.conf)

    if (( ${#files[@]} == 0 )); then
        echo "No tunnels configured."
        return 0
    fi

    local file state
    for file in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$file"

        if [[ "$ENABLED" != "yes" ]]; then
            state="disabled"
        elif ip link show "$NAME" >/dev/null 2>&1; then
            state="up"
        else
            state="down"
        fi

        printf "%-15s %-8s %-15s %-15s %-18s %-15s %-5s\n" \
            "$NAME" "$state" "$LOCAL_PUBLIC" "$REMOTE_PUBLIC" \
            "$LOCAL_CIDR" "$REMOTE_TUN_IP" "$MTU"
    done
}

cmd_status() {
    [[ $# -eq 1 ]] || die "Usage: ipip-manager status <name>"

    local name="$1"
    load_config "$name"

    echo "Name:          $NAME"
    echo "Enabled:       $ENABLED"
    echo "Local public:  $LOCAL_PUBLIC"
    echo "Remote public: $REMOTE_PUBLIC"
    echo "Local tunnel:  $LOCAL_CIDR"
    echo "Remote tunnel: $REMOTE_TUN_IP"
    echo "MTU:           $MTU"
    echo

    if ip link show "$NAME" >/dev/null 2>&1; then
        echo "Runtime state: UP"
        echo
        ip -d tunnel show "$NAME" || true
        ip addr show "$NAME" || true
        echo
        echo "Route to remote tunnel IP:"
        ip route get "$REMOTE_TUN_IP" || true
    else
        echo "Runtime state: DOWN"
    fi
}

cmd_test() {
    [[ $# -eq 1 ]] || die "Usage: ipip-manager test <name>"

    local name="$1"
    load_config "$name"

    echo "Pinging $REMOTE_TUN_IP through $NAME ..."
    ping -I "$NAME" -c 4 "$REMOTE_TUN_IP"
}

cmd_restore() {
    ensure_dirs
    modprobe ipip

    shopt -s nullglob
    local files=("$CONFIG_DIR"/*.conf)

    for file in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$file"

        if [[ "${ENABLED:-no}" == "yes" ]]; then
            echo "Restoring $NAME ..."
            tunnel_up "$NAME"
        fi
    done
}

cmd_setup() {
    need_root

    ensure_dirs

    # Install this script to a stable location.
    local source_script
    source_script="$(readlink -f "$0")"

    if [[ "$source_script" != "$INSTALL_PATH" ]]; then
        install -m 0755 "$source_script" "$INSTALL_PATH"
    else
        chmod 0755 "$INSTALL_PATH"
    fi

    echo "ipip" > "$MODULE_FILE"

    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Restore IPIP tunnels
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ipip-manager restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ipip-manager.service

    echo "Installed: $INSTALL_PATH"
    echo "Enabled persistence service: ipip-manager.service"
    echo
    echo "Existing enabled tunnels will be restored automatically after reboot."
}

cmd_uninstall_service() {
    need_root

    systemctl disable --now ipip-manager.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$MODULE_FILE"
    systemctl daemon-reload

    echo "Persistence service removed."
    echo "Tunnel configuration files were kept in $CONFIG_DIR"
}

usage() {
    cat <<'EOF'
IPIP Tunnel Manager

Usage:
  ipip-manager setup

  ipip-manager add <name> <local-public> <remote-public> <local-cidr> <remote-tun-ip> [mtu]
  ipip-manager edit <name> <local-public> <remote-public> <local-cidr> <remote-tun-ip> [mtu]
  ipip-manager delete <name>

  ipip-manager up <name>
  ipip-manager down <name>
  ipip-manager restart <name>

  ipip-manager enable <name>
  ipip-manager disable <name>

  ipip-manager list
  ipip-manager status <name>
  ipip-manager test <name>
  ipip-manager restore

  ipip-manager uninstall-service

Examples on HUB:

  ipip-manager add vps1 \
    203.0.113.10 \
    198.51.100.20 \
    10.77.0.1/30 \
    10.77.0.2

  ipip-manager add vps2 \
    203.0.113.10 \
    198.51.100.21 \
    10.77.0.5/30 \
    10.77.0.6

Examples on remote VPS1:

  ipip-manager add hub \
    198.51.100.20 \
    203.0.113.10 \
    10.77.0.2/30 \
    10.77.0.1

Examples on remote VPS2:

  ipip-manager add hub \
    198.51.100.21 \
    203.0.113.10 \
    10.77.0.6/30 \
    10.77.0.5

Notes:
  - Interface names are limited to 15 characters.
  - Default MTU is 1480.
  - IPIP uses IP protocol 4.
  - This script does NOT modify your firewall automatically.
EOF
}

main() {
    need_root

    local command="${1:-help}"
    shift || true

    case "$command" in
        setup)
            cmd_setup "$@"
            ;;
        add)
            cmd_add "$@"
            ;;
        edit)
            cmd_edit "$@"
            ;;
        delete|del|remove)
            cmd_delete "$@"
            ;;
        up)
            [[ $# -eq 1 ]] || die "Usage: ipip-manager up <name>"
            tunnel_up "$1"
            ;;
        down)
            [[ $# -eq 1 ]] || die "Usage: ipip-manager down <name>"
            tunnel_down "$1"
            ;;
        restart)
            [[ $# -eq 1 ]] || die "Usage: ipip-manager restart <name>"
            tunnel_down "$1"
            tunnel_up "$1"
            ;;
        enable)
            cmd_enable_tunnel "$@"
            ;;
        disable)
            cmd_disable_tunnel "$@"
            ;;
        list|ls)
            cmd_list
            ;;
        status)
            cmd_status "$@"
            ;;
        test|ping)
            cmd_test "$@"
            ;;
        restore)
            cmd_restore
            ;;
        uninstall-service)
            cmd_uninstall_service
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
