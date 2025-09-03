#!/bin/bash
set -eu

### ===== Functions =====
die(){ echo "ERROR: $*" >&2; exit 1; }

### ===== Pre-flight =====
[ "$(id -u)" -eq 0 ] || die "Run as root (sudo -i)."
command -v wg >/dev/null 2>&1 || apt-get update -y && apt-get install -y wireguard wireguard-tools
apt-get install -y qrencode >/dev/null 2>&1 || true

# Hard LF line endings (in case pulled from Windows)
command -v dos2unix >/dev/null 2>&1 && dos2unix "$0" >/dev/null 2>&1 || true

### ===== Vars (edit if needed) =====
ENDPOINT_IP="${ENDPOINT_IP:-162.19.204.74}"
ENDPOINT_PORT="${ENDPOINT_PORT:-51820}"

LAN_CIDR="${LAN_CIDR:-10.10.0.0/24}"
LAN_GW="${LAN_GW:-10.10.0.1}"
VPN_NET="${VPN_NET:-10.11.0.0/24}"
VPN_SRV_IP="${VPN_SRV_IP:-10.11.0.1/24}"

# Fixed client IPs
declare -A PEERS=(
  [henri]="10.11.0.2/32"
  [jerre]="10.11.0.3/32"
  [willy]="10.11.0.4/32"
  [keem]="10.11.0.5/32"
)

WG_DIR="/etc/wireguard"
CLIENT_DIR="/root/wg-clients"
WG_IF="wg0"

# Detect LAN interface that carries $LAN_CIDR; fallback ens19
LAN_IF="$(ip -o -4 addr show | awk -v cidr="$LAN_CIDR" '$0 ~ cidr {print $2; exit}')"
LAN_IF="${LAN_IF:-ens19}"

### ===== Nuking (clean slate) =====
systemctl stop "wg-quick@${WG_IF}" 2>/dev/null || true
wg-quick down "${WG_IF}" 2>/dev/null || true
rm -f "${WG_DIR}/${WG_IF}.conf" "${WG_DIR}/server.key" "${WG_DIR}/server.pub"
rm -rf "${CLIENT_DIR}"
install -d -m 700 "${CLIENT_DIR}"
install -d -m 700 "${WG_DIR}"

### ===== System settings =====
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-ipforward.conf
sysctl --system >/dev/null

### ===== Server keys =====
umask 077
wg genkey | tee "${WG_DIR}/server.key" | wg pubkey > "${WG_DIR}/server.pub"
SERVER_PRIV="$(cat "${WG_DIR}/server.key")"
SERVER_PUB="$(cat "${WG_DIR}/server.pub")"

### ===== Server config =====
cat >"${WG_DIR}/${WG_IF}.conf" <<EOF
[Interface]
Address = ${VPN_SRV_IP}
ListenPort = ${ENDPOINT_PORT}
PrivateKey = ${SERVER_PRIV}

# Forward/NAT VPN -> LAN via ${LAN_IF}
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${VPN_NET} -o ${LAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${VPN_NET} -o ${LAN_IF} -j MASQUERADE
EOF
chmod 600 "${WG_DIR}/${WG_IF}.conf"

### ===== Clients =====
for u in "${!PEERS[@]}"; do
  wg genkey | tee "${CLIENT_DIR}/${u}.key" | wg pubkey > "${CLIENT_DIR}/${u}.pub"
  PRIV="$(cat "${CLIENT_DIR}/${u}.key")"
  PUB="$(cat "${CLIENT_DIR}/${u}.pub")"
  IP="${PEERS[$u]}"

  # Append peer to server
  cat >>"${WG_DIR}/${WG_IF}.conf" <<EOF

[Peer]
# ${u}
PublicKey = ${PUB}
AllowedIPs = ${IP}
EOF

  # Client config
  cat >"${CLIENT_DIR}/${u}.conf" <<CFG
[Interface]
PrivateKey = ${PRIV}
Address = ${IP}
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${ENDPOINT_IP}:${ENDPOINT_PORT}
AllowedIPs = ${LAN_CIDR}, ${VPN_NET}
PersistentKeepalive = 25
CFG

  chmod 600 "${CLIENT_DIR}/${u}.conf" "${CLIENT_DIR}/${u}.key"
  # Optional QR (voor mobiel)
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "${CLIENT_DIR}/${u}.conf" > "${CLIENT_DIR}/${u}.qr.txt" || true
  fi
done

### ===== Bring-up =====
systemctl enable --now "wg-quick@${WG_IF}"
systemctl is-active --quiet "wg-quick@${WG_IF}" || die "wg-quick@${WG_IF} failed to start. Check: journalctl -u wg-quick@${WG_IF} -e"

### ===== Output =====
echo
echo "========== WireGuard READY =========="
echo "Server pubkey : ${SERVER_PUB}"
echo "WG interface  : ${WG_IF} on ${VPN_SRV_IP}"
echo "LAN iface     : ${LAN_IF} (${LAN_CIDR}) via GW ${LAN_GW}"
echo "Clients dir   : ${CLIENT_DIR}  (henri/jerre/willy/keem .conf + .qr.txt)"
echo "Status        : wg show"
echo "====================================="
