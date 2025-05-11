#!/usr/bin/env bash
#
# Purpose:
#   Install CUDA drivers, Git, SSH keys and configure GitHub access,
#   validate CUDA installation with samples, install pyenv and set up a Python
#   environment for a given repository.
#
# Requirements:
#   - This script is intended for Ubuntu-based systems.
#   - Required arguments: GIT_REPO, GIT_USERNAME, GIT_EMAIL, GIT_PAT, INSTANCE_NAME, PYENV_VERSION.
#   - It uses sudo for package installations.
#
# Usage:
#   ./this_script.sh <GIT_REPO> <GIT_USERNAME> <GIT_EMAIL> <GIT_PAT> <INSTANCE_NAME> <PYENV_VERSION>

# -----------------------------------------------------------------------------
#   Enable strict mode for safer scripting:
#     - -E: Inherit ERR traps in functions/subshells.
#     - -e: Exit immediately on error.
#     - -u: Treat unset variables as errors.
#     - -o pipefail: Pipeline returns exit code of the last failed command.
# -----------------------------------------------------------------------------
set -Eeuo pipefail

# Validate that all required arguments are provided.
if [[ "$#" -ne 6 ]]; then
    echo "Usage: $0 <GIT_REPO> <GIT_USERNAME> <GIT_EMAIL> <GIT_PAT> <INSTANCE_NAME> <PYENV_VERSION>"
    exit 1
fi

# Assign command-line arguments to variables
GIT_REPO="$1"
GIT_USERNAME="$2"
GIT_EMAIL="$3"
GIT_PAT="$4"
INSTANCE_NAME="$5"
PYENV_VERSION="$6"

# Update and upgrade the system quietly.
update_linux() {
    echo -e "===== Updating and upgrading Linux =====\n"
    sudo apt-get update -qq && sudo apt-get upgrade -y -qq

}

# Check if CUDA is installed, else install CUDA toolkit
install_cuda_toolkit() {

    CUDA_PATH="/usr/local/cuda-12.8/bin"
    CUDA_LD_LIBRARY_PATH="/usr/local/cuda-12.8/lib64"
    if [[ -d "$CUDA_PATH" && -x "$CUDA_PATH/nvcc" ]]; then
        echo -e "\n===== CUDA Toolkit is already installed =====\n"
        export PATH="$CUDA_PATH:$PATH"
        export LD_LIBRARY_PATH="$CUDA_LD_LIBRARY_PATH:${LD_LIBRARY_PATH:-}"
        nvcc --version
    else
        echo -e "\n===== Installing CUDA Toolkit =====\n"
        CUDA_DRIVER_INSTALL_FILE="cuda-keyring_1.1-1_all.deb"
        if [[ ! -f "$CUDA_DRIVER_INSTALL_FILE" ]]; then
            wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
        fi
        sudo dpkg -i "$CUDA_DRIVER_INSTALL_FILE"
        sudo apt-get update -qq
        sudo apt-get install -y -qq cuda-toolkit-12-8

        echo -e "\n===== Adding CUDA to PATH =====\n"
        # Append CUDA paths to .bashrc if not already added
        if ! grep -q "$CUDA_PATH" ~/.bashrc; then
            echo "export PATH=$CUDA_PATH:\$PATH" >>~/.bashrc
            echo "export LD_LIBRARY_PATH=$CUDA_LD_LIBRARY_PATH:\$LD_LIBRARY_PATH" >>~/.bashrc
        fi
        export PATH="$CUDA_PATH:$PATH"
        export LD_LIBRARY_PATH="$CUDA_LD_LIBRARY_PATH:${LD_LIBRARY_PATH:-}"

        # Check nsights compute and nvcc versions
        nvcc --version
        ncu --version
    fi
}

set_nsights_compute_permissions() {
    # In order to gain access to Nsights Compute, need to run following code below, reboot required
    echo "options nvidia NVreg_RestrictProfilingToAdminUsers=0" | sudo tee -a /etc/modprobe.d/nvidia.conf
    # sudo update-initramfs -u
    # sudo reboot
}

install_git() {
    echo -e "\n===== Installing Git and Other Dependencies =====\n"
    sudo apt-get install -y -qq git git-lfs tmux unzip
}

generate_ssh_key() {
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        echo -e "\n===== Generating SSH key for GitHub =====\n"
        ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY_PATH" -N ""
    else
        echo -e "\n===== $SSH_KEY_PATH already exists. Skipping creation =====\n"
    fi
}

# Ensure .ssh directory exists (create if missing)
create_ssh_dir() {
    if [[ ! -d "$HOME/.ssh" ]]; then
        echo -e "\n===== Creating $HOME/.ssh directory =====\n"
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
    else
        echo -e "\n===== $HOME/.ssh already exists. Skipping creation =====\n"
    fi
}

# Ensure SSH config file exists
create_ssh_config_file() {
    if [[ ! -f "$SSH_CONFIG" ]]; then
        echo -e "\n===== Creating SSH config file =====\n"
        touch "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
    else
        echo -e "\n===== $SSH_CONFIG already exists. Skipping creation =====\n"
    fi
}

# Add GitHub configuration to SSH config file if not present.
add_github_to_ssh_config() {
    if ! grep -q "Host github.com" "$SSH_CONFIG"; then
        echo -e "\n===== Adding github.com to SSH config file =====\n"
        {
            echo -e "\nHost github.com"
            echo -e "  HostName github.com"
            echo -e "  User git"
            echo -e "  IdentityFile $SSH_KEY_PATH"
            echo -e "  IdentitiesOnly yes"
        } >>"$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
    else
        echo -e "\n===== github.com is already added to SSH config file =====\n"
    fi
}

# Ensure the SSH agent is running and set environment variables.
source_ssh_agent() {
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
        if [[ -f "$HOME/.ssh/ssh-agent.env" ]]; then
            # Use the previously saved environment variables
            source "$HOME/.ssh/ssh-agent.env"
        else
            # Fallback: manually set SSH_AUTH_SOCK, but note SSH_AGENT_PID might be missing!
            SSH_AUTH_SOCK=$(find /tmp -type s -name "agent.*" 2>/dev/null | head -n 1)
            export SSH_AUTH_SOCK
            if [[ -z "$SSH_AUTH_SOCK" ]]; then
                echo -e "\n===== Warning: Unable to find a valid SSH agent socket =====\n"
            fi
        fi
    fi
}

# Add the SSH key to the agent if not already added.
add_ssh_key_to_agent() {
    if ssh-add -L | grep -q "$(cat "$SSH_KEY_PATH".pub)"; then
        echo -e "\n===== SSH key is already added. Skipping ssh-add =====\n"
    else
        echo -e "\n===== Adding SSH key to the SSH agent =====\n"
        ssh-add "$SSH_KEY_PATH"
    fi
}

# Fetch existing SSH keys from GitHub, then check if local SSH key matches
find_existing_github_ssh_key() {
    # Fetch existing SSH keys from GitHub
    EXISTING_KEYS=$(curl -s -H "Authorization: token $GIT_PAT" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/user/keys)

    # Loop through existing keys and compare fingerprints
    LOCAL_FP=$(ssh-keygen -lf "$SSH_PUB_KEY_FILE" | awk '{print $2}')
    MATCH_FOUND=false
    while IFS= read -r KEY; do
        if [[ "$KEY" =~ ^ssh-(rsa|ed25519|dss|ecdsa) ]]; then
            EXISTING_FP=$(ssh-keygen -lf <(echo "$KEY") | awk '{print $2}')
            if [[ "$EXISTING_FP" == "$LOCAL_FP" ]]; then
                MATCH_FOUND=true
                break
            fi
        fi
    done < <(echo "$EXISTING_KEYS" | jq -r ".[].key")

    if [[ "$MATCH_FOUND" == true ]]; then
        echo -e "\n===== SSH key already exists in GitHub. Skipping key upload =====\n"
    else
        echo -e "\n===== Uploading SSH key to GitHub =====\n"
        curl -X POST -H "Authorization: token $GIT_PAT" \
            -H "Accept: application/vnd.github.v3+json" \
            https://api.github.com/user/keys \
            -d "{\"title\":\"$GIT_SSH_KEY_NAME\",\"key\":\"$SSH_PUB_KEY\"}"
        echo -e "\n===== SSH key successfully added to GitHub =====\n"
    fi
}

add_github_ssh_to_known_hosts() {
    echo -e "\n===== Adding GitHub to known_hosts =====\n"
    ssh-keygen -R github.com 2>/dev/null || true
    ssh-keyscan -H github.com >>~/.ssh/known_hosts 2>/dev/null || {
        echo -e "\n===== Error: Failed to add github.com to known_hosts ====="
        exit 1
    }
    chmod 600 ~/.ssh/known_hosts
}

test_ssh_github_auth() {
    echo -e "\n===== Testing SSH authentication with GitHub =====\n"
    SSH_OUTPUT=$(ssh -T git@github.com 2>&1 || true)
    echo -e "$SSH_OUTPUT"
    if echo "$SSH_OUTPUT" | grep -q "successfully authenticated"; then
        echo -e "\n===== SSH authentication to GitHub succeeded. =====\n"
    else
        echo -e "\n===== SSH authentication to GitHub failed. Exiting. =====\n"
        exit 1
    fi
}

# Create a directory for GitHub repositories if it does not exist.
create_github_user_local_dir() {
    if [[ ! -d "$GIT_USERNAME" ]]; then
        echo -e "\n===== Creating directory for user $GIT_USERNAME =====\n"
        mkdir "$GIT_USERNAME"
    else
        echo -e "\n===== Directory $GIT_USERNAME already exists. Skipping creation =====\n"
    fi
}

# Clone the GitHub repository if not already present.
clone_github_repo() {
    cd "$GIT_USERNAME" || exit
    REPO_NAME=$(basename "$GIT_REPO" .git)
    if [[ ! -d "$REPO_NAME" ]]; then
        echo -e "\n===== Cloning repository: $REPO_NAME =====\n"
        git clone "$GIT_REPO"
        cd "$REPO_NAME" || exit
        git remote set-url origin "$GIT_REPO"
    else
        echo -e "\n===== Repository $REPO_NAME already exists. Skipping clone =====\n"
    fi
}

config_git_global_user_details() {
    echo -e "\n===== Configuring Git user details =====\n"
    git config --global user.email "$GIT_EMAIL"
    git config --global user.name "$GIT_USERNAME"
    cd ~ || exit
}

# Validate CUDA installation using cuda-samples (repo via GitHub)
validate_cuda() {
    if [[ ! -d "cuda-samples" ]]; then
        echo -e "\n===== Cloning cuda-samples and validating CUDA =====\n"
        git clone https://github.com/NVIDIA/cuda-samples.git

        echo -e "\n===== Installing cmake =====\n"
        sudo apt-get install -y -qq cmake
        cmake --version

        cd ~/cuda-samples/Samples/0_Introduction/vectorAdd || exit
        mkdir -p build && cd build || exit
        cmake ..
        make -j"$(nproc)"

        echo -e "\n===== Running the vectorAdd CUDA sample =====\n"
        output=$(./vectorAdd 2>&1)
        echo "$output"

        if echo "$output" | grep -q "Test PASSED" && echo "$output" | grep -q "Done"; then
            echo -e "\n===== CUDA Validation Successful =====\n"
        else
            echo -e "\n===== ERROR: CUDA Validation Failed =====\n"
            exit 1
        fi
    else
        echo -e "\n===== cuda-samples already exists. Skipping CUDA validation =====\n"
    fi
}

# Install pyenv (if not already installed) and set up a virtualenv.
install_pyenv() {
    if [ -x "$HOME/.pyenv/bin/pyenv" ]; then
        echo -e "\n===== pyenv is already installed. Skipping installation =====\n"
    else
        echo -e "\n===== Installing pyenv dependencies =====\n"
        sudo apt-get install -y -qq make build-essential libssl-dev zlib1g-dev \
            libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
            libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
            libffi-dev liblzma-dev

        echo -e "\n===== Installing pyenv =====\n"
        curl https://pyenv.run | bash

        # Append pyenv configuration to .bashrc if not already present
        if ! grep -q 'PYENV_ROOT' ~/.bashrc; then
            {
                echo 'export PYENV_ROOT="$HOME/.pyenv"'
                echo 'export PATH="$PYENV_ROOT/bin:$PATH"'
                echo 'eval "$(pyenv init --path)"'
                echo 'eval "$(pyenv init -)"'
                echo 'eval "$(pyenv virtualenv-init -)"'
            } >>"$HOME/.bashrc"
        fi

        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        # shellcheck source=/dev/null
        source "$HOME/.bashrc"

        if ! command -v pyenv &>/dev/null; then
            echo -e "\n===== Error: pyenv command not found. Exiting. =====\n"
            exit 1
        fi

        echo -e "\n===== pyenv installed successfully! Installing Python $PYENV_VERSION =====\n"
        pyenv install "$PYENV_VERSION"
        pyenv virtualenv "$PYENV_VERSION" "${REPO_NAME}-pyenv"

        cd ~/"$GIT_USERNAME"/"$REPO_NAME" || exit
        pyenv local "${REPO_NAME}-pyenv"
        python -m pip install --upgrade pip
    fi
}

# Teardown: remove unnecessary files.
teardown() {
    echo -e "\n===== Initiating teardown: Removing unnecessary files =====\n"
    cd ~ || exit
    rm -f .wget-hsts
    rm -f cuda-keyring_1.1-1_all.deb
    rm -rf cuda-samples
    rm -rf setup_scripts
}

echo -e "\n===== Downloading CUDA Drivers ====="
update_linux
install_cuda_toolkit
# set_nsights_compute_permissions
install_git

# Generate SSH key for GitHub if it doesn't exist.
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_${GIT_USERNAME}"
SSH_CONFIG="$HOME/.ssh/config"

generate_ssh_key
create_ssh_dir
create_ssh_config_file
add_github_to_ssh_config
source_ssh_agent
add_ssh_key_to_agent

# Fetch the public key and check if it is already uploaded to GitHub.
SSH_PUB_KEY_FILE="$HOME/.ssh/id_ed25519_${GIT_USERNAME}.pub"
SSH_PUB_KEY=$(cat "$SSH_PUB_KEY_FILE")
GIT_SSH_KEY_NAME="${INSTANCE_NAME}-ssh-key"

find_existing_github_ssh_key
add_github_ssh_to_known_hosts
test_ssh_github_auth
create_github_user_local_dir
clone_github_repo
config_git_global_user_details
validate_cuda
install_pyenv
teardown

echo -e "\n===== Setup completed successfully! =====\n"
exit 0
