#!/usr/bin/env bash
set -e

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

# Require root
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0"
fi

echo -e "${YELLOW}[*] Updating system and installing dependencies...${NC}"

apt-get update
apt-get upgrade -y

apt-get install -y \
curl \
wget \
git \
software-properties-common \
ca-certificates \
gnupg \
lsb-release

# Install Fastfetch if missing
if ! command -v fastfetch >/dev/null 2>&1; then
    add-apt-repository ppa:zhangsongcui3371/fastfetch -y
    apt-get update
    apt-get install -y fastfetch
fi

clear
fastfetch

echo
echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}      Cloudflared Tunnel Installer${NC}"
echo -e "${CYAN}==============================================${NC}"
echo

echo -e "${YELLOW}[*] Installing/Updating Cloudflared...${NC}"

mkdir -p --mode=0755 /usr/share/keyrings

curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
| tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
> /etc/apt/sources.list.d/cloudflared.list

apt-get update
apt-get install -y cloudflared

echo
echo -e "${GREEN}Paste your Cloudflare Tunnel Token below.${NC}"
echo

read -rp "Tunnel Token: " TOKEN

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
Restart=always
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared >/dev/null 2>&1
systemctl restart cloudflared

echo
echo -e "${YELLOW}[*] Checking service status...${NC}"
sleep 5

if systemctl is-active --quiet cloudflared; then
    clear
    fastfetch

    echo
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}        ✓ Cloudflared Installed Successfully${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo
    systemctl --no-pager --full status cloudflared
else
    echo
    echo -e "${RED}====================================================${NC}"
    echo -e "${RED}        ✗ Cloudflared Failed To Start${NC}"
    echo -e "${RED}====================================================${NC}"
    echo
    journalctl -u cloudflared --no-pager -n 50
    exit 1
fi

echo
echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE} Tunnel installation completed successfully!${NC}"
echo -e "${BLUE}====================================================${NC}"
echo
echo -e "${YELLOW}If your tunnel token was previously shared publicly,${NC}"
echo -e "${YELLOW}rotate it in the Cloudflare Zero Trust dashboard.${NC}"
echo
