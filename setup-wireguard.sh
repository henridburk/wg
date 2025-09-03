#!/bin/bash
set -eu

# =========================
# CONFIG — pas alleen aan indien nodig
# =========================
ENDPOINT_IP="162.19.204.74"
ENDPOINT_PORT="51820"

LAN_CIDR="10.10.0.0/24"
LAN_GW="10.10.0.1"           # Proxmox host
VPN_NET="10.11.0.0/24"
VPN_SRV_IP="10.11.0.1/24"

# Vaste client IP's
declare -A PEERS=(
  [henri]="10.11.0.2/32"
  [jerre]="10.11.0.3/32"
  [willy]="10.11.0.4/32"
  [keem]="10.11.0.5/32"
)

# Probe: welke NIC hangt aan het LAN? (val terug op ens19)
LAN_IF="$(ip -o -4 addr show | awk -v cidr="$LAN_CIDR" '$0 ~ cidr {print $2; exit}')"
LAN_IF="${LAN_IF:-ens19}"

WG_DIR="/etc/wireguard"
CLIENT_DIR="/root/wg-clients"
WG_IF="wg0"

# =========================
# Checks & packages
# =========================
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

echo "[+] Installing packages…"
apt-get update -y
apt-get install -y wireguard qrencode >/dev/null || apt-get install -y wireguard

# Enable IP forwarding (runtime + persistent)
echo "[+] Enabling IPv4 forwarding…"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-ipforward.conf
sysctl --system >/dev/null

# =========================
# Netplan sanity (1 NIC op LAN met default route via host)
# — alleen informeren; geen harde overwrite om jouw netplan niet stuk te maken.
# =========================
echo "[i] Gebruik LAN interface: $LAN_IF (probe)"
echo "[i] Zorg dat deze VM een default route via $LAN_GW heeft (via $LAN_IF)."

# =========================
# WireGuard server keys
# =========================
mkdir -p "$WG_DIR" "$CLIENT_DIR"
chmod 700 "$WG_DIR" "$CLIENT_DIR"
umask 077

if [ ! -f "$WG_DIR/server.key" ]; then
  echo "[+] Generating server keypair…"
  wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub"
fi

SERVER_PRIV="$(cat "$WG_DIR/server.key")"
SERVER_PUB="$(cat "$WG_DIR/server.pub")"

# =========================
# Server config
# =========================
echo "[+] Writing $WG_DIR/${WG_IF}.conf…"
cat >"$WG_DIR/${WG_IF}.conf" <<EOF
[Interface]
Address = ${VPN_SRV_IP}
ListenPort = ${ENDPOINT_PORT}
PrivateKey = ${SERVER_PRIV}

# Allow VPN <-> LAN forwarding + NAT richting LAN via ${LAN_IF}
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${VPN_NET} -o ${LAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${VPN_NET} -o ${LAN_IF} -j MASQUERADE
EOF

# =========================
# Peers genereren
# =========================
echo "[+] Generating peers (clients)…"
for user in "${!PEERS[@]}"; do
  C_IP="${PEERS[$user]}"
  # make keys if not exists
  [ -f "$CLIENT_DIR/${user}.key" ] || wg genkey | tee "$CLIENT_DIR/${user}.key" | wg pubkey > "$CLIENT_DIR/${user}.pub"
  C_PRIV="$(cat "$CLIENT_DIR/${user}.key")"
  C_PUB="$(cat "$CLIENT_DIR/${user}.pub")"

  # append to server config
  cat >>"$WG_DIR/${WG_IF}.conf" <<EOF

[Peer]
# ${user}
PublicKey = ${C_PUB}
AllowedIPs = ${C_IP}
EOF

  # client config file
  cat >"$CLIENT_DIR/${user}.conf" <<CFG
[Interface]
PrivateKey = ${C_PRIV}
Address = ${C_IP}
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${ENDPOINT_IP}:${ENDPOINT_PORT}
AllowedIPs = ${LAN_CIDR}, ${VPN_NET}
PersistentKeepalive = 25
CFG

  # QR code (if qrencode exists)
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$CLIENT_DIR/${user}.conf" > "$CLIENT_DIR/${user}.qr.txt" || true
  fi
done

chmod 600 "$WG_DIR/${WG_IF}.conf"
chmod 600 "$CLIENT_DIR"/*.key "$CLIENT_DIR"/*.conf 2>/dev/null || true

# =========================
# Service enable
# =========================
echo "[+] Enabling and starting wg-quick@${WG_IF}…"
systemctl enable --now "wg-quick@${WG_IF}"

echo
echo "================ DONE ================"
echo "Server pubkey: ${SERVER_PUB}"
echo "LAN IF used  : ${LAN_IF}"
echo "Client files : ${CLIENT_DIR}/ (henri/jerre/willy/keem .conf)"
echo "Show status  : sudo wg show"
echo "======================================"

