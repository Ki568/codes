#!/usr/bin/env bash
set -e

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

clear

echo -e "${BLUE}"
echo "=============================================="
echo "      Cloudflared Auto Installer & Fix"
echo "=============================================="
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0"
fi

echo -e "${YELLOW}[*] Installing/Updating Cloudflared...${NC}"

mkdir -p --mode=0755 /usr/share/keyrings

curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
| tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
> /etc/apt/sources.list.d/cloudflared.list

apt-get update
apt-get install -y cloudflared

echo
read -rp "Enter your Cloudflare Tunnel Token: " TOKEN

mkdir -p /etc/cloudflared
echo "$TOKEN" >/etc/cloudflared/token
chmod 600 /etc/cloudflared/token

cat >/etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --protocol http2 --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

sleep 3

echo
systemctl --no-pager status cloudflared

if systemctl is-active --quiet cloudflared; then
    echo
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN} Cloudflared Installed Successfully ${NC}"
    echo -e "${GREEN} Tunnel Status: ONLINE              ${NC}"
    echo -e "${GREEN}====================================${NC}"
else
    echo
    echo -e "${RED}Cloudflared failed to start.${NC}"
    echo
    journalctl -u cloudflared --no-pager -n 50
fi
