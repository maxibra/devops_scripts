#!/bin/bash

shrc="${HOME}/.zshrc"
python_version_to_install="3.13.2"
GREEN='\033[0/;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "- Enable Locate command\n=====================\n"
sudo /usr/libexec/locate.updatedb 
echo -e "\n--------------------------------------------------\n"

# BREW
brew -v
if [ $? -gt 0 ]; then 
  echo -e "- Installing Brew\n=====================\n"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [ -z "$(grep 'brew shellenv' ~/.zshrc)" ]; then 
    echo "# BREW" >> ${shrc}
    echo "eval \"$($(brew --prefix)/bin/brew shellenv)\"" >> ${shrc}
    echo "#==================================================" >> ${shrc}
  fi
else
  echo -e "${GREEN}Brew is already installed${NC}\n"
fi
echo -e "\n--------------------------------------------------\n"

# iTerm2
if [ -z "$(brew list | grep iterm2)" ]; then
  echo -e "- Installing Iterm2\n=====================\n"
  brew install --cask iterm2
else
  echo -e "${GREEN}iTerm2 is already installed${NC}\n"
fi 
echo -e "\n--------------------------------------------------\n"

# Oh My Zsh
if [ ! -d ${HOME}/.oh-my-zsh ]; then
  echo -e "- Installing Oh My Zsh\n=====================\n"
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
  echo -e "${GREEN}Oh My Zsh is already installed. Upgrading...${NC}\n"
  ~/.oh-my-zsh/tools/upgrade.sh
fi
echo -e "\n--------------------------------------------------\n"

# powerlevel10k
if [ -z "$(find ~/.oh-my-zsh -type d -name '*powerlevel10k*')" ]; then
  echo -e "- Installing powerlevel10k Theme\n=====================\n"
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
  source ${HOME}/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme
  p10k configure
  if [ -z "$(grep 'ZSH_THEME=' ${shrc} | grep 'powerlevel10k/powerlevel10k')" ]; then
    echo -e "\t${RED}Please set ZSH_THEME=\"powerlevel10k/powerlevel10k\"${NC}\n"
    sleep 10
    # echo 'source ~/powerlevel10k/powerlevel10k.zsh-theme' >>~/.zshrc # Isn't required if ZSH_THEME defined properly
  fi
else
  echo -e "${GREEN}powerlevel10k Theme is already installed${NC}\n"
fi 
echo -e "\n--------------------------------------------------\n"

# ZSH-AUTOSUGGESTIONS
if [ -z "$(find ${HOME}/.oh-my-zsh/custom/plugins -type d -name zsh-autosuggestions)" ]; then 
  echo -e "- Installing ZSH Plugin zsh-autosuggestions\n=====================\n"
  git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custo
m}/plugins/zsh-autosuggestions
else
  echo -e "${GREEN} ZSH Plugin zsh-autosuggestion is already installed${NC}\n"
  if [ -z "$(grep -A10 'plugins=' ${shrc} | grep zsh-autosuggestions)" ]; then
    echo -e "\t${RED}Please add zsh-autosuggestions to 'plugins=()'${NC}\n"
    sleep 10
  fi
fi 
echo -e "\n--------------------------------------------------\n"

# JQ
jq --version 2>/dev/null
if [ $? -gt 0 ]; then
  echo -e "- Installing JQ\n=====================\n"
  brew install jq
else
  echo -e "${GREEN}JQ is already installed${NC}\n"
fi 
echo -e "\n--------------------------------------------------\n"

# PYENV and python 3.13.2
pyenv -v 2>/dev/null
if [ $? -gt 0 ]; then
  echo -e "- Installing Pyenv\n=====================\n"
  brew install pyenv
  if [ -z "$(pyenv versions | grep ${python_version_to_install})" ]; then
    echo -e "- Installing Python Version ${python_version_to_install}\n=====================\n"
    pyenv install ${python_version_to_install}
  fi
else
  echo -e "${GREEN}PYENV is already installed${NC}\n"
fi 
echo -e "${GREEN}\tUse 'pyenv shell|local|global <version>' to select the required python version{NC}\n" 
echo -e "\n--------------------------------------------------\n"

# AWS CLI
aws --version 2>/dev/null
if [ $? -gt 0 ]; then
  echo -e "- Installing AWS CLI\n=====================\n"
  brew install awscli
else
  echo -e "${GREEN}AWS CLI is already installed${NC}\n"
fi 
echo -e "\n--------------------------------------------------\n"

# Terraform
terraform --version 2>/dev/null
if [ $? -gt 0 ]; then
  brew tap hashicorp/tap
  brew install hashicorp/tap/terraform
  brew install terraform-docs
  brew install tflint
else
  echo -e "${GREEN}Terraform is already installed${NC}\n"
fi 

# GIT configs
brew install gh
ls ${HOME}/.gitignore_global 2>/dev/null
if [ $? -gt 0 ]; then
  echo -e "- Installing ${HOME}/.gitignore_global\n=====================\n"
  touch ${HOME}/.gitignore_global
  git config --global core.excludesfile ${HOME}/.gitignore_global
fi
if [ -z "$(git config --get user.name)" ]; then
  echo -e "- Setting Git user.name to ${USER}\n=====================\n"
  git config --global user.name ${USER}
fi
git config --global core.pager cat  # Git commands output to stdout
echo -e "\n--------------------------------------------------\n"

# Kubernets
echo -e "- Installing Kubernetes Tools\n=====================\n"
brew install kubectx
brew install kubectl
brew install k9s
echo -e "\n--------------------------------------------------\n"
