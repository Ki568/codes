#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PANEL_PATH="/var/www/pterodactyl"

pause(){
  read -p "Press Enter to return to main menu..."
}

while true; do
clear
echo -e "${CYAN}=============================="
echo -e "      DEVIN VPS TOOLKIT"
echo -e "==============================${NC}"
echo "1) SSH Fixer"
echo "2) Panel Installer"
echo "3) Themes + Addons"
echo "4) Change Root Password"
echo "5) Install Tailscale"
echo "6) Cloudflare Tunnel Setup"
echo "7) Exit"
echo "=============================="

read -p "Select option [1-7]: " choice

case $choice in

1)
    echo -e "${GREEN}Fixing SSH config...${NC}"

    sudo bash -c 'cat <<EOF > /etc/ssh/sshd_config
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

Subsystem sftp /usr/lib/openssh/sftp-server
EOF

systemctl restart ssh 2>/dev/null || service ssh restart
'

    echo -e "${GREEN}SSH Fixed Successfully!${NC}"
    pause
    ;;

2)
    echo -e "${GREEN}Installing Panel...${NC}"
    bash <(curl -s https://pterodactyl-installer.se)
    pause
    ;;

3)
while true; do
clear
echo -e "${CYAN}=============================="
echo -e "      THEMES & ADDONS"
echo -e "==============================${NC}"
echo "1) Install Dashboard"
echo "2) Install Blueprint"
echo "3) Install Addons (Auto)"
echo "4) Install Theme (Auto)"
echo "5) Back"
echo "=============================="

read -p "Select option [1-5]: " dashchoice

case $dashchoice in

1)
    echo -e "${GREEN}Installing Dashboard...${NC}"

    sudo apt update
    sudo apt install git curl -y

    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install nodejs -y

    git clone https://github.com/MythicalLTD/MythicalDash.git
    cd MythicalDash || exit

    npm install
    nohup npm start > /dev/null 2>&1 &

    echo -e "${GREEN}Dashboard Installed & Running!${NC}"
    pause
    ;;

2)
    echo -e "${GREEN}Installing Blueprint...${NC}"

    cd $PANEL_PATH || { echo "Panel not found!"; pause; break; }

    bash <(curl -s https://blueprint.zip/install.sh)

    echo -e "${GREEN}Blueprint Installed!${NC}"
    pause
    ;;

3)
    echo -e "${GREEN}Installing Addons Automatically...${NC}"

    cd $PANEL_PATH || { echo "Panel not found!"; pause; break; }

    bash <(curl -fsSL https://raw.githubusercontent.com/hopingboyz/blueprint/main/addon-installer.sh)

    echo -e "${GREEN}All Addons Installed Successfully!${NC}"
    pause
    ;;

4)
    echo -e "${GREEN}Installing Themes Automatically...${NC}"

    cd $PANEL_PATH || { echo "Panel not found!"; pause; break; }

    bash <(curl -fsSL https://raw.githubusercontent.com/hopingboyz/blueprint/main/blueprint-installer.sh)

    echo -e "${GREEN}All Themes Installed Successfully!${NC}"
    pause
    ;;

5)
    break
    ;;

*)
    echo -e "${RED}Invalid option!${NC}"
    sleep 2
    ;;

esac
done
;;

4)
    echo -e "${GREEN}Changing Root Password...${NC}"
    sudo passwd root
    pause
    ;;

5)
    echo -e "${GREEN}Installing Tailscale...${NC}"
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up
    pause
    ;;

6)
    echo -e "${GREEN}Installing Cloudflared...${NC}"

    sudo mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list

    sudo apt-get update && sudo apt-get install cloudflared -y

    echo ""
    read -p "Enter your Cloudflare Tunnel Token: " token

    sudo cloudflared service install $token
    sudo systemctl start cloudflared
    sudo systemctl enable cloudflared

    echo -e "${GREEN}Cloudflare Tunnel Installed & Running!${NC}"
    pause
    ;;

7)
    echo "Exiting..."
    exit
    ;;

*)
    echo -e "${RED}Invalid option!${NC}"
    sleep 2
    ;;

esac

done
