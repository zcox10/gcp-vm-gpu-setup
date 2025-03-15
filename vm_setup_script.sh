#!/bin/bash

# Update and upgrade the system
echo -e "\n===== Downloading CUDA Drivers ====="
echo -e "===== Updating and upgrading Linux =====\n"
sudo apt-get update -qq && sudo apt-get upgrade -y -qq

# Check if CUDA is installed by verifying both directories exist and nvcc is present
CUDA_PATH="/usr/local/cuda-12.8/bin"
CUDA_LD_LIBRARY_PATH="/usr/local/cuda-12.8/lib64"
if [[ -d "$CUDA_PATH" && -x "$CUDA_PATH/nvcc" ]]; then
    echo -e "\n===== CUDA Toolkit is already installed =====\n"
    export PATH="$CUDA_PATH:$PATH"
    export LD_LIBRARY_PATH="$CUDA_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
    nvcc --version
else
    echo -e "\n===== Installing CUDA Toolkit =====\n"
    CUDA_DRIVER_INSTALL_FILE="cuda-keyring_1.1-1_all.deb"
    if [[ ! -f $CUDA_DRIVER_INSTALL_FILE ]]; then
        wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
    fi
    sudo dpkg -i $CUDA_DRIVER_INSTALL_FILE
    sudo apt-get update -qq
    sudo apt-get install -y -qq cuda-toolkit-12-8

    echo -e "\n===== Add CUDA to PATH =====\n"
    echo "export PATH=$CUDA_PATH:\$PATH" >>~/.bashrc
    echo "export LD_LIBRARY_PATH=$CUDA_LD_LIBRARY_PATH:\$LD_LIBRARY_PATH" >>~/.bashrc
    export PATH="$CUDA_PATH:$PATH"
    export LD_LIBRARY_PATH="$CUDA_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
    nvcc --version
fi

echo -e "\n===== Installing Git =====\n"
# Read arguments and install Git
GIT_REPO=$1
GIT_USERNAME=$2
GIT_EMAIL=$3
GIT_PAT=$4
INSTANCE_NAME=$5
PYENV_VERSION=$6
sudo apt-get install -y -qq git

# Generate SSH key (if it does not already exist)
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_${GIT_USERNAME}"
SSH_CONFIG="$HOME/.ssh/config"
if [[ ! -f $SSH_KEY_PATH ]]; then
    echo -e "\n===== Generating SSH key for GitHub =====\n"
    ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY_PATH" -N ""
else
    echo -e "\n===== $SSH_KEY_PATH already exists. Skipping creation =====\n"
fi

# Ensure .ssh directory exists
if [[ ! -d "$HOME/.ssh" ]]; then
    echo -e "\n===== Creating $HOME/.ssh dir =====\n"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
else
    echo -e "\n===== $HOME/.ssh already exists. Skipping creation =====\n"
fi

# Ensure config file exists
if [[ ! -f "$SSH_CONFIG" ]]; then
    echo -e "\n===== Creating SSH config file =====\n"
    touch "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
else
    echo -e "\n===== $SSH_CONFIG already exists. Skipping creation =====\n"
fi

# Add GitHub configuration to the SSH config file
if ! grep -q "Host github.com" "$SSH_CONFIG"; then
    echo -e "\n===== Adding github.com to config file =====\n"

    {
        echo -e "\nHost github.com"
        echo -e "  HostName github.com"
        echo -e "  User git"
        echo -e "  IdentityFile $SSH_KEY_PATH"
        echo -e "  IdentitiesOnly yes\n"
    } >>"$SSH_CONFIG"

    chmod 600 "$SSH_CONFIG"
else
    echo -e "\n===== github.com is already added to config file =====\n"
fi

# Ensure SSH agent is running and set environment variables
if ! pgrep -x ssh-agent >/dev/null; then
    echo -e "\n===== Starting SSH agent =====\n"
    ssh-agent -s >"$HOME/.ssh/ssh-agent.env"

    if [[ -f "$HOME/.ssh/ssh-agent.env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.ssh/ssh-agent.env"
    else
        echo -e "\n===== Error: Failed to create ~/.ssh/ssh-agent.env =====\n"
        exit 1
    fi

else
    echo -e "\n===== SSH agent is already running =====\n"

    # Find the running SSH agent's socket dynamically
    SSH_AUTH_SOCK=$(find /tmp -type s -name "agent.*" 2>/dev/null | head -n 1)
    export SSH_AUTH_SOCK

    if [[ -z "$SSH_AUTH_SOCK" ]]; then
        echo -e "\n===== Warning: Unable to find a valid SSH agent socket =====\n"
    fi
fi

# Check if the key is already added (by content, not filename)
if ssh-add -L | grep -q "$(cat "$SSH_KEY_PATH".pub)"; then
    echo -e "\n===== SSH key is already added. Skipping ssh-add =====\n"
else
    echo -e "\n===== Perform ssh-add =====\n"
    ssh-add "$SSH_KEY_PATH"
fi

# Fetch existing SSH keys and check if the key is already added
SSH_PUB_KEY_FILE="$HOME/.ssh/id_ed25519_${GIT_USERNAME}.pub"
SSH_PUB_KEY=$(cat "$SSH_PUB_KEY_FILE")
GIT_SSH_KEY_NAME="$INSTANCE_NAME-ssh-key"

# Fetch existing SSH keys from GitHub
EXISTING_KEYS=$(curl -s -H "Authorization: token $GIT_PAT" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/user/keys)

# Loop through existing keys and check if the fingerprint matches local SSH key fingerprint
LOCAL_FP=$(ssh-keygen -lf "$SSH_PUB_KEY_FILE" | awk '{print $2}')
MATCH_FOUND=false
while IFS= read -r KEY; do
    # Ensure the key starts with a valid SSH prefix
    if [[ "$KEY" =~ ^ssh-(rsa|ed25519|dss|ecdsa) ]]; then
        # Convert GitHub's key to fingerprint
        EXISTING_FP=$(ssh-keygen -lf <(echo "$KEY") | awk '{print $2}')

        if [[ "$EXISTING_FP" == "$LOCAL_FP" ]]; then
            MATCH_FOUND=true
            break
        fi
    fi
done < <(echo "$EXISTING_KEYS" | jq -r ".[].key")

# Determine if needing to add SSH key to GitHub
if [[ "$MATCH_FOUND" == true ]]; then
    echo -e "\n===== SSH key already exists in GitHub. Skipping key upload =====\n"
else
    echo -e "\n===== Adding SSH key to GitHub =====\n"
    curl -X POST -H "Authorization: token $GIT_PAT" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/user/keys \
        -d "{\"title\":\"$GIT_SSH_KEY_NAME\",\"key\":\"$SSH_PUB_KEY\"}"
    echo -e "\n===== Key successfully added to GitHub =====\n"
fi

# Ensure GitHub's SSH fingerprint is added to known_hosts
echo -e "\n===== Adding GitHub to known_hosts =====\n"
ssh-keygen -R github.com 2>/dev/null           # remove stale entries of github.com
ssh-keyscan -H github.com >>~/.ssh/known_hosts # add github.com to known hosts
chmod 600 ~/.ssh/known_hosts

# Test SSH authentication
echo -e "\n===== Testing SSH authentication with GitHub =====\n"
if ! ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo -e "===== SSH authentication to GitHub failed. Exiting. ====="
    exit 1
fi

# Create directory for github repos
if [[ ! -d "$GIT_USERNAME" ]]; then
    echo -e "\n===== Creating directory for user $GIT_USERNAME =====\n"
    mkdir "$GIT_USERNAME"
else
    echo -e "\n===== Directory $GIT_USERNAME already exists. Skipping creation. =====\n"
fi

# Check if the repo exists in <username>/<repo_name>; create it if it doesn't
cd "$GIT_USERNAME" || exit
REPO_NAME=$(basename "$GIT_REPO" .git)

if [[ ! -d "$REPO_NAME" ]]; then
    echo -e "\n===== Cloning $REPO_NAME =====\n"
    git clone "$GIT_REPO"
    git remote set-url origin "$GIT_REPO"
else
    echo -e "\n===== $REPO_NAME already exists. Skipping creation. =====\n"
fi

# Configure Git for repo
echo -e "\n===== Configuring Git user details for this repository =====\n"
git config --global user.email "$GIT_EMAIL"
git config --global user.name "$GIT_USERNAME"
cd ~ || exit

# CUDA Validation
if [[ ! -d cuda-samples ]]; then
    echo -e "\n===== Clone cuda-samples and validate CUDA =====\n"
    git clone https://github.com/NVIDIA/cuda-samples.git

    echo -e "\n===== Install cmake and validate version =====\n"
    sudo apt-get install -y -qq cmake
    cmake --version

    cd ~/cuda-samples/Samples/0_Introduction/vectorAdd || exit
    mkdir -p build && cd build || exit
    cmake ..
    make -j"$(nproc)"

    echo -e "\n===== Running the vectorAdd CUDA sample =====\n"
    output=$(./vectorAdd 2>&1)
    echo "$output" # print output

    # Check if both "Test PASSED" and "Done" are in the output
    if echo "$output" | grep -q "Test PASSED" && echo "$output" | grep -q "Done"; then
        echo -e "\n===== CUDA Validation Successful =====\n"
    else
        echo -e "\n===== ERROR: CUDA Validation Failed =====\n"
        exit 1
    fi
else
    echo -e "\n===== cuda-samples already exists. Skipping validation. =====\n"
fi

# Install pyenv
if ! command -v pyenv &>/dev/null; then
    echo -e "\n===== Installing pyenv dependencies =====\n"
    sudo apt-get install -y -qq make build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
        libffi-dev liblzma-dev

    echo -e "\n===== Installing pyenv =====\n"
    curl https://pyenv.run | bash

    # Add pyenv configuration to .bashrc
    # shellcheck disable=SC2016
    {
        echo 'export PYENV_ROOT="$HOME/.pyenv"'
        echo 'export PATH="$PYENV_ROOT/bin:$PATH"'
        echo 'eval "$(pyenv init --path)"'
        echo 'eval "$(pyenv init -)"'
        echo 'eval "$(pyenv virtualenv-init -)"'
    } >>"$HOME/.bashrc"

    # Apply changes for current script session
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"

    # shellcheck source=/dev/null
    source "$HOME/.bashrc"

    # Verify pyenv is available
    if ! command -v pyenv &>/dev/null; then
        echo -e "\n===== Error: pyenv command still not found. Exiting. =====\n"
        exit 1
    fi

    echo -e "\n===== pyenv installed successfully! Installing Python $PYENV_VERSION =====\n"
    pyenv install "$PYENV_VERSION"
    pyenv virtualenv "$PYENV_VERSION" "$REPO_NAME-pyenv"

    # Set pyenv as local to github repo
    cd ~/"$GIT_USERNAME"/"$REPO_NAME" || exit
    pyenv local "$REPO_NAME-pyenv"

else
    echo -e "\n===== pyenv is already installed. Skipping installation. =====\n"
fi

echo -e "\n===== Initiate teardown. Removing unnecessary files  =====\n"
cd ~ || exit
rm -f .wget-hsts
rm -f cuda-keyring_1.1-1_all.deb
rm -rf cuda-samples
rm -rf setup_scripts

# Final message
echo -e "\n===== Setup completed successfully! =====\n"
exit 0
