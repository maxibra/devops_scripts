#!/bin/bash
# The script was created for Mint/Ubuntu based distributions

sudo apt update
sudo apt install -y \
    git \
    vim \
    zsh

mkdir -p $HOME/.keys

echo "Configuring git..."
git config --global user.name "MB"
git config --global user.email "my.email@gmail.com"
echo "Generating Github ssh key..."
GITHUB_KEY_FILE="$HOME/.keys/github-my_personal_id_ed25519"
if [ ! -f "$GITHUB_KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f $GITHUB_KEY_FILE -N ""
    chmod 600 $GITHUB_KEY_FILE
    echo "Here is the public key to add to your GitHub account:"
    cat $GITHUB_KEY_FILE.pub              
fi


echo "Installing Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

echo "Installing Powerlevel10k theme..."
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
fi
# Set ZSH_THEME in .zshrc
sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' $HOME/.zshrc

echo "Installing zsh plugins..."
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions   
fi 
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
fi
# Add plugins to .zshrc — replace entire plugins line with desired list
sed -i 's/^plugins=(.*)/plugins=(git docker terraform kubectl helm zsh-autosuggestions zsh-syntax-highlighting)/' "$HOME/.zshrc"

echo "installing Meslo LGS NF fonts for Powerlevel10k..."
MESLO_TMP="$(mktemp -d)"
MESLO_ZIP="$MESLO_TMP/meslo.zip"
FONTS_DIR="$HOME/.local/share/fonts"

mkdir -p "$FONTS_DIR"

echo "Downloading Meslo Nerd Font..."
curl -fL --retry 3 -o "$MESLO_ZIP" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"

echo "Extracting and installing Meslo fonts to $FONTS_DIR..."
unzip -o "$MESLO_ZIP" -d "$MESLO_TMP"
# copy TTF files that include Meslo into fonts dir
find "$MESLO_TMP" -type f -iname "*Meslo*.ttf" -exec cp -v {} "$FONTS_DIR/" \;

echo "Updating font cache..."
fc-cache -fv "$FONTS_DIR"
sudo dpkg-reconfigure fontconfig
gsettings get org.gnome.desktop.interface monospace-font-name
gsettings set org.gnome.desktop.interface monospace-font-name 'MesloLGS NF 14'

# cleanup
rm -rf "$MESLO_TMP"

# Source .zshrc to apply changes
source $HOME/.zshrc

echo "Installing Docker..."
if ! command -v docker &> /dev/null; then
#     sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc | cut -f1)
#     # Add Docker's official GPG key:
#     sudo apt update\nsudo apt install ca-certificates curl
#     sudo install -m 0755 -d /etc/apt/keyrings
#     sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
#     sudo chmod a+r /etc/apt/keyrings/docker.asc
#     # Add the repository to Apt sources:
#     sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
# Types: deb
# URIs: https://download.docker.com/linux/ubuntu
# Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
# Components: stable
# Signed-By: /etc/apt/keyrings/docker.asc
# EOF
#     sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    sudo groupadd docker 2>/dev/null
    sudo usermod -aG docker $USER
fi

echo "Mounting HomePlus on the SSD Disk (Lenovo Flex 3)..."
SSD_MOUNT_POINT="${HOME}/HomePlus"
if ! grep -qs "$SSD_MOUNT_POINT" /proc/mounts; then
    echo -e "UUID=$(sudo blkid /dev/sda9 | cut -d'"' -f2) $SSD_MOUNT_POINTq\text4\tdefaults,nofail\t0\t2" | sudo tee -a /etc/fstab
    sudo mount -a
    systemctl daemon-reload
fi

echo "Configuring connection to Raspbery cluster..."
RASPBERRY_KEY_FILE="$HOME/.keys/raspberryPi_id_ed25519"
if [ ! -f "$RASPBERRY_KEY_FILE" ]; then
    mkdir -p $HOME/.keys
    ssh-keygen -t ed25519 -f $RASPBERRY_KEY_FILE -N ""
    chmod 600 $RASPBERRY_KEY_FILE
    echo "Here is the public key to add to your GitHub account:"
    cat $RASPBERRY_KEY_FILE.pub   
    # ssh-copy-id -i $HOME/.keys/raspberryPi_id_ed25519.pub pi@k8s-0
fi

sudo tee -a /etc/hosts <<EOF
# Raspberry Pi cluster
192.168.0.110 k8s-0
192.168.0.111 k8s-1
192.168.0.112 k8s-2
192.168.0.113 k8s-3
EOF

echo "Configuring SSH config file..."
SSH_CONFIG_FILE="$HOME/.ssh/config"
if [ ! -f "$SSH_CONFIG_FILE" ]; then
    mkdir -p "$HOME/.ssh"
    tee -a "$SSH_CONFIG_FILE" <<EOF
# github private account
Host github.com-personal
    HostName github.com
    PreferredAuthentications publickey
    IdentityFile ~/.keys/github-my_personal_id_ed25519

# Raspberry
Host k8s-0 k8s-1 k8s-2 k8s-3
    HostName %h
    IdentityFile ~/.keys/raspberryPi_id_ed25519
    IdentitiesOnly yes           
    StrictHostKeyChecking no    
    UserKnownHostsFile /dev/null 
EOF
    chmod 600 "$SSH_CONFIG_FILE"
fi  




