#!/bin/bash
# The script was created for Mint/Ubuntu based distributions

# Fail fast and be strict about undefined variables
set -euo pipefail
IFS=$'\n\t'

err() {
    echo "[ERROR] $*" >&2
}

log() {
    echo "[INFO] $*"
}

# small download helper: try curl then wget
download_to_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$out" "$url" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$url" && return 0
    fi
    return 1
}

# CLI flags
FORCE=false
while [ "${1:-}" != "" ]; do
    case "$1" in
        -f|--force)
            FORCE=true
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: linux_init_installation.sh [--force] [--help]

Options:
  -f, --force    Force reinstallation of fonts and re-adding/reinstalling repos/packages
  -h, --help     Show this help
USAGE
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

sudo apt update
# install core packages (non-interactive)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    jq \
    npm \
    pre-commit \
    vim \
    yq \
    zsh \
    curl \
    unzip \
    fontconfig \
    ca-certificates

mkdir -p "$HOME/.keys"

echo "Configuring git..."
git config --global user.name "MB"
git config --global user.email "my.email@gmail.com"
echo "Generating Github ssh key..."
GITHUB_KEY_FILE="$HOME/.keys/github-my_personal_id_ed25519"
if [ ! -f "$GITHUB_KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f "$GITHUB_KEY_FILE" -N ""
    chmod 600 "$GITHUB_KEY_FILE"
    echo "Here is the public key to add to your GitHub account:"
    cat $GITHUB_KEY_FILE.pub              
fi


log "Installing nvm and Node 20 (LTS)"
NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh"
NVM_DIR="$HOME/.nvm"

# If node v20 is already installed and force is not set, skip
if [ "$FORCE" != true ] && command -v node >/dev/null 2>&1 && node -v | grep -qE '^v20\.'; then
    log "Node v20 already installed and active; skipping nvm/node install."
else
    NVM_TMP_DIR="$(mktemp -d)"
    NVM_SCRIPT="$NVM_TMP_DIR/install_nvm.sh"
    if download_to_file "$NVM_INSTALL_URL" "$NVM_SCRIPT"; then
        bash "$NVM_SCRIPT" || true
        # Load nvm for this script's session
        export NVM_DIR="$NVM_DIR"
        if [ -s "$NVM_DIR/nvm.sh" ]; then
            # shellcheck source=/dev/null
            . "$NVM_DIR/nvm.sh"
        fi

        # Install and set Node 20
        if command -v nvm >/dev/null 2>&1; then
            log "Using nvm to install Node 20"
            nvm install 20 || true
            nvm use 20 || true
            nvm alias default 20 || true
            log "Node 20 installed and set as default via nvm"
        else
            err "nvm installation succeeded but 'nvm' command is not available in this shell. You may need to start a new shell or source \"$NVM_DIR/nvm.sh\"."
        fi
    else
        err "Failed to download nvm install script from $NVM_INSTALL_URL"
    fi
    rm -rf "$NVM_TMP_DIR" || true
fi

log "Installing Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

log "Installing Powerlevel10k theme..."
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
fi
# Set ZSH_THEME in .zshrc (use extended regex for safety)
if [ -f "$HOME/.zshrc" ]; then
    sed -i -E 's/^ZSH_THEME=.*$/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$HOME/.zshrc"
fi

log "Installing zsh plugins..."
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions   
fi 
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
fi
# Add plugins to .zshrc — replace entire plugins line with desired list (use extended regex)
if [ -f "$HOME/.zshrc" ]; then
    sed -i -E 's/^plugins=\(.*/plugins=(git docker terraform kubectl helm zsh-autosuggestions zsh-syntax-highlighting)/' "$HOME/.zshrc"
fi

log "Installing Meslo LGS NF fonts for Powerlevel10k..."
MESLO_TMP="$(mktemp -d)"
MESLO_ZIP="$MESLO_TMP/meslo.zip"
FONTS_DIR="$HOME/.local/share/fonts"

mkdir -p "$FONTS_DIR"
# Skip installation if Meslo fonts already present (unless forced)
if [ "$FORCE" != true ] && command -v fc-list >/dev/null 2>&1 && fc-list | grep -qi 'MesloLGS'; then
    log "MesloLGS NF already installed (fontconfig). Skipping font install."
elif [ "$FORCE" != true ] && find "$FONTS_DIR" -type f -iname "*Meslo*.ttf" -print -quit >/dev/null 2>&1; then
    log "Meslo LGS NF TTF files already exist in $FONTS_DIR. Skipping font install."
else
    log "Downloading Meslo Nerd Font..."
    if ! download_to_file "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip" "$MESLO_ZIP"; then
        err "Failed to download Meslo.zip — please check your network or visit https://github.com/ryanoasis/nerd-fonts/releases"
    else
        echo "Extracting and installing Meslo fonts to $FONTS_DIR..."
        unzip -o "$MESLO_ZIP" -d "$MESLO_TMP" >/dev/null 2>&1 || true
        # copy TTF files that include Meslo into fonts dir
        find "$MESLO_TMP" -type f -iname "*Meslo*.ttf" -exec cp -v {} "$FONTS_DIR/" \; || true

        log "Updating font cache..."
        fc-cache -fv "$FONTS_DIR" >/dev/null 2>&1 || true

        # Try to set monospace font for GNOME/Cinnamon if gsettings is available
        if command -v gsettings >/dev/null 2>&1; then
            for schema in org.cinnamon.desktop.interface org.gnome.desktop.interface; do
                if gsettings writable "$schema" monospace-font-name >/dev/null 2>&1; then
                    gsettings set "$schema" monospace-font-name 'MesloLGS NF 14' >/dev/null 2>&1 || true
                fi
            done
        fi

        # cleanup
        rm -rf "$MESLO_TMP"
        log "Meslo LGS NF installation finished (user fonts: $FONTS_DIR). Restart your terminal or log out/in to apply fonts."
    fi
fi

log "Installing Docker..."
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

log "Mounting HomePlus on the SSD Disk (Lenovo Flex 3)..."
SSD_MOUNT_POINT="${HOME}/HomePlus"
if ! grep -qs "$SSD_MOUNT_POINT" /proc/mounts; then
    echo -e "UUID=$(sudo blkid /dev/sda9 | cut -d'"' -f2) $SSD_MOUNT_POINTq\text4\tdefaults,nofail\t0\t2" | sudo tee -a /etc/fstab
    sudo mount -a
    systemctl daemon-reload
fi

echo "Configuring connection to Raspbery cluster..."
RASPBERRY_KEY_FILE="$HOME/.keys/raspberryPi_id_ed25519"
if [ ! -f "$RASPBERRY_KEY_FILE" ]; then
    mkdir -p "$HOME/.keys"
    ssh-keygen -t ed25519 -f "$RASPBERRY_KEY_FILE" -N ""
    chmod 600 "$RASPBERRY_KEY_FILE"
    echo "Here is the public key to add to your GitHub account:"
    cat $RASPBERRY_KEY_FILE.pub   
    # ssh-copy-id -i $HOME/.keys/raspberryPi_id_ed25519.pub pi@k8s-0
fi

# Raspberry Pi cluster — append entries idempotently
hosts_entries=(
    "192.168.0.110 k8s-0"
    "192.168.0.111 k8s-1"
    "192.168.0.112 k8s-2"
    "192.168.0.113 k8s-3"
)
for entry in "${hosts_entries[@]}"; do
    if ! grep -qF -- "$entry" /etc/hosts; then
        echo "$entry" | sudo tee -a /etc/hosts >/dev/null
        log "Added /etc/hosts entry: $entry"
    else
        log "/etc/hosts already contains: $entry"
    fi
done

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

echo "Installing VSCode (if not present)..."
REPO_PATTERN='packages.microsoft.com/repos/vscode'
if [ "$FORCE" = true ]; then
    log "Force mode: will re-add VSCode repository and reinstall package if present."
    # Remove existing references to the repo to avoid duplicates
    sudo sed -i.bak -E "/${REPO_PATTERN//\//\\/}/d" /etc/apt/sources.list || true
    for f in /etc/apt/sources.list.d/*; do
        if [ -f "$f" ] && grep -q "$REPO_PATTERN" "$f" 2>/dev/null; then
            sudo rm -f "$f" || true
        fi
    done
fi

if ! command -v code >/dev/null 2>&1; then
    # Add Microsoft repo only if missing (or after FORCE cleanup above)
    if ! grep -R --quiet "$REPO_PATTERN" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        wget -q https://packages.microsoft.com/keys/microsoft.asc -O- | sudo apt-key add - || true
        sudo add-apt-repository -y "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main" || true
    else
        log "VSCode apt repository already present; skipping add-apt-repository"
    fi
    sudo apt-get update
    sudo apt-get install -y code || true
else
    if [ "$FORCE" = true ]; then
        log "Force mode: reinstalling VSCode package"
        sudo apt-get update
        sudo apt-get install --reinstall -y code || true
    else
        log "VSCode currently installed; skipping install"
    fi
fi

# Install common extensions (if code is available)
if command -v code >/dev/null 2>&1; then
    extensions=(
        ms-azuretools.vscode-docker
        GitHub.copilot
        GitHub.copilot-chat
        github.vscode-pull-request-github
        hashicorp.terraform
        ms-python.python
        mechatroner.rainbow-csv
        ms-kubernetes-tools.vscode-kubernetes-tools
        oderwat.indent-rainbow
    )
    for e in "${extensions[@]}"; do
        code --install-extension "$e" >/dev/null 2>&1 || true
    done
    code --list-extensions --show-versions
else
    echo "VSCode not found: skipping extension installation. Install 'code' first to add extensions automatically."
fi


