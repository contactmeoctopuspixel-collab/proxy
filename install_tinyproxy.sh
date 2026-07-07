#!/usr/bin/env bash
set -Eeuo pipefail

# Tinyproxy installer for Ubuntu/Debian
#
# Usage:
#   sudo bash install_tinyproxy.sh
#   sudo bash install_tinyproxy.sh USERNAME PORT
#   sudo bash install_tinyproxy.sh USERNAME PORT PASSWORD
#
# Examples:
#   sudo bash install_tinyproxy.sh
#   sudo bash install_tinyproxy.sh proxyuser 3128
#   sudo bash install_tinyproxy.sh proxyuser 3128 'StrongPasswordHere'
#
# The proxy accepts clients from any IPv4 address, but BasicAuth is mandatory.
# Do not remove BasicAuth unless the port is protected by a VPN/private network.

trap 'echo "ERROR: Installation failed near line $LINENO." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this installer as root:"
    echo "  sudo bash $0"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: /etc/os-release was not found."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        echo "ERROR: This installer supports Ubuntu and Debian only."
        echo "Detected OS: ${PRETTY_NAME:-unknown}"
        exit 1
        ;;
esac

PROXY_USER="${1:-proxyuser}"
PROXY_PORT="${2:-3128}"
PROXY_PASSWORD="${3:-}"

if [[ ! "$PROXY_USER" =~ ^[A-Za-z][A-Za-z0-9_.-]{2,31}$ ]]; then
    echo "ERROR: Invalid proxy username."
    echo "Use 3-32 characters: letters, numbers, dot, underscore, or dash."
    exit 1
fi

if [[ ! "$PROXY_PORT" =~ ^[0-9]+$ ]] ||
   (( PROXY_PORT < 1024 || PROXY_PORT > 65535 )); then
    echo "ERROR: Port must be an integer between 1024 and 65535."
    exit 1
fi

if [[ -z "$PROXY_PASSWORD" ]]; then
    # Strong hexadecimal password without shell-sensitive characters.
    PROXY_PASSWORD="$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')"
fi

if (( ${#PROXY_PASSWORD} < 12 )); then
    echo "ERROR: The proxy password must contain at least 12 characters."
    exit 1
fi

# Tinyproxy's BasicAuth directive is whitespace-delimited.
if [[ "$PROXY_PASSWORD" =~ [[:space:]] ]]; then
    echo "ERROR: The proxy password cannot contain spaces or tabs."
    exit 1
fi

if [[ "$PROXY_PASSWORD" == *"#"* ]]; then
    echo "ERROR: The proxy password cannot contain #."
    exit 1
fi

echo "Installing Tinyproxy on ${PRETTY_NAME:-Linux}..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends tinyproxy curl ca-certificates iproute2

# Stop the previous proxy services so the chosen port can be reused.
for service in squid squid3 danted; do
    if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null |
       grep -q "^${service}\.service"; then
        systemctl disable --now "$service" 2>/dev/null || true
    fi
done

CONFIG_DIR="/etc/tinyproxy"
CONFIG_FILE="${CONFIG_DIR}/tinyproxy.conf"
BACKUP_FILE=""

mkdir -p "$CONFIG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP_FILE="${CONFIG_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_FILE" "$BACKUP_FILE"
fi

# The Ubuntu/Debian package normally creates these. Re-create only if absent.
if ! getent group tinyproxy >/dev/null; then
    groupadd --system tinyproxy
fi

if ! id tinyproxy >/dev/null 2>&1; then
    useradd \
        --system \
        --gid tinyproxy \
        --home-dir /run/tinyproxy \
        --shell /usr/sbin/nologin \
        tinyproxy
fi

install -d -o tinyproxy -g tinyproxy -m 0750 /var/log/tinyproxy
install -d -o tinyproxy -g tinyproxy -m 0755 /run/tinyproxy

cat > "$CONFIG_FILE" <<CONF
# Managed by install_tinyproxy.sh
#
# Publicly reachable HTTP/HTTPS CONNECT proxy protected by BasicAuth.
# There are intentionally no Allow directives, so authenticated clients
# may connect from changing/dynamic public IP addresses.

User tinyproxy
Group tinyproxy

Port ${PROXY_PORT}
Listen 0.0.0.0
Timeout 600

DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"

LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"

MaxClients 100
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0

ViaProxyName "tinyproxy"
DisableViaHeader Yes

# Access is denied unless these credentials are supplied.
BasicAuth ${PROXY_USER} ${PROXY_PASSWORD}
BasicAuthRealm "Private proxy"

# Permit HTTPS tunnels only to standard TLS ports.
ConnectPort 443
ConnectPort 563
CONF

chmod 640 "$CONFIG_FILE"
chown root:tinyproxy "$CONFIG_FILE"

systemctl daemon-reload
systemctl enable tinyproxy >/dev/null

if ! systemctl restart tinyproxy; then
    echo "ERROR: Tinyproxy did not start."
    journalctl -u tinyproxy -n 100 --no-pager || true

    if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
        echo "Restoring previous Tinyproxy configuration..."
        cp -a "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart tinyproxy 2>/dev/null || true
    fi

    exit 1
fi

sleep 1

if ! systemctl is-active --quiet tinyproxy; then
    echo "ERROR: Tinyproxy is not active."
    journalctl -u tinyproxy -n 100 --no-pager || true
    exit 1
fi

if ! ss -lnt | awk -v port=":${PROXY_PORT}" '$4 ~ port"$" {found=1} END {exit !found}'; then
    echo "ERROR: Nothing is listening on TCP port ${PROXY_PORT}."
    ss -lntp || true
    exit 1
fi

# Open the port only when UFW is already enabled.
if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PROXY_PORT}/tcp" comment "Authenticated Tinyproxy" >/dev/null
fi

PUBLIC_IP="$(
    curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null ||
    curl -4fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null ||
    true
)"

CREDENTIAL_FILE="/root/tinyproxy-credentials.txt"
cat > "$CREDENTIAL_FILE" <<CREDS
Proxy type: HTTP/HTTPS CONNECT
Proxy IP: ${PUBLIC_IP:-YOUR_SERVER_PUBLIC_IP}
Proxy port: ${PROXY_PORT}
Username: ${PROXY_USER}
Password: ${PROXY_PASSWORD}

Proxy URL:
http://${PROXY_USER}:${PROXY_PASSWORD}@${PUBLIC_IP:-YOUR_SERVER_PUBLIC_IP}:${PROXY_PORT}

Test:
curl -fsS -x 'http://${PROXY_USER}:${PROXY_PASSWORD}@${PUBLIC_IP:-YOUR_SERVER_PUBLIC_IP}:${PROXY_PORT}' https://api.ipify.org
CREDS

chmod 600 "$CREDENTIAL_FILE"

echo
echo "============================================================"
echo " Tinyproxy installation completed"
echo "============================================================"
echo "Proxy type : HTTP/HTTPS CONNECT"
echo "Proxy IP   : ${PUBLIC_IP:-YOUR_SERVER_PUBLIC_IP}"
echo "Proxy port : ${PROXY_PORT}"
echo "Username   : ${PROXY_USER}"
echo "Password   : ${PROXY_PASSWORD}"
echo
echo "AWS Security Group — configure once:"
echo "  Protocol: TCP"
echo "  Port:     ${PROXY_PORT}"
echo "  Source:   0.0.0.0/0"
echo
echo "Remove the old public inbound rule for Squid if it uses"
echo "a different port. Squid has been stopped and disabled."
echo
echo "Test from your computer:"
echo "  curl -x 'http://${PROXY_USER}:${PROXY_PASSWORD}@${PUBLIC_IP:-YOUR_SERVER_PUBLIC_IP}:${PROXY_PORT}' https://api.ipify.org"
echo
echo "Credentials were also saved to:"
echo "  ${CREDENTIAL_FILE}"
echo
echo "Logs:"
echo "  sudo tail -f /var/log/tinyproxy/tinyproxy.log"
echo "============================================================"
