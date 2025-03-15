#!/usr/bin/env bash
#
# Purpose:
#   Acquire a GPU-enabled VM on GCP via a Python script, then prepare and SSH into it.
#
# Requirements:
#   - 'python3', 'jq', 'yq', 'nc', 'ssh', and 'scp' must be installed and available in PATH.
#   - A valid 'config.yaml' with the required fields.
#   - 'create_gcp_vm_instance.py' and 'vm_setup_script.sh' must be present.
#

# -----------------------------------------------------------------------------
#   Enable strict error handling and safer scripting:
#   - -E: Inherit ERR traps in functions and subshells.
#   - -e: Exit immediately if a command exits with a non-zero status.
#   - -u: Treat unset variables as an error.
#   - -o pipefail: Pipeline returns the exit code of the last command to fail.
# -----------------------------------------------------------------------------
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# (CHANGES MADE):
#   Add a helper function to verify required commands exist.
# -----------------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1 || {
        echo >&2 "Error: Required command '$1' not found in PATH."
        exit 1
    }
}

# Check for required commands
command_exists python3
command_exists jq
command_exists yq
command_exists nc
command_exists ssh
command_exists scp

echo -e "\n===== Acquiring a GPU from GCP =====\n"

# -----------------------------------------------------------------------------
#   Capture the Python script output and its exit code for error handling.
# -----------------------------------------------------------------------------
PYTHON_OUTPUT="$(python3 create_gcp_vm_instance.py 2>&1 || true)"
PYTHON_EXIT_CODE=$?
if [[ $PYTHON_EXIT_CODE -ne 0 ]]; then
    echo "\n===== Error: 'create_gcp_vm_instance.py' failed with exit code $PYTHON_EXIT_CODE. ====="
    echo "Output was: $PYTHON_OUTPUT"
    exit $PYTHON_EXIT_CODE
fi

# Expect the final line of output to be JSON
OUTPUT="$(echo "$PYTHON_OUTPUT" | tail -n 1)"

# Validate that OUTPUT is valid JSON
if ! echo "$OUTPUT" | jq empty >/dev/null 2>&1; then
    echo "\n===== Error: The final line of Python output is not valid JSON. Got:"
    echo "$OUTPUT"
    exit 1
fi

# Parse returned JSON values and print to verify
GCP_PROJECT_ID="$(echo "$OUTPUT" | jq -r '.GCP_PROJECT_ID')"
ZONE="$(echo "$OUTPUT" | jq -r '.ZONE')"
INSTANCE_NAME="$(echo "$OUTPUT" | jq -r '.INSTANCE_NAME')"
EXTERNAL_IP="$(echo "$OUTPUT" | jq -r '.EXTERNAL_IP')"

echo -e "\n===== Python VM Script Output ====="
echo "GCP_PROJECT_ID: $GCP_PROJECT_ID"
echo "ZONE: $ZONE"
echo "INSTANCE_NAME: $INSTANCE_NAME"
echo -e "EXTERNAL_IP: $EXTERNAL_IP\n"

# -----------------------------------------------------------------------------
# (CHANGES MADE):
#   Validate that we obtained a non-empty, non-null external IP.
# -----------------------------------------------------------------------------
if [[ -z "$EXTERNAL_IP" || "$EXTERNAL_IP" == "null" ]]; then
    echo -e "\n===== Failed to retrieve a valid external IP =====\n"
    exit 1
fi

# -----------------------------------------------------------------------------
# Read variables from config.yaml for SSH into VM
# -----------------------------------------------------------------------------
SSH_USER="$(yq e '.ssh.ssh_user' config.yaml)"
SSH_KEY_PATH="$(yq e '.ssh.ssh_key_path' config.yaml)"

# Validate SSH config values
if [[ -z "$SSH_USER" || "$SSH_USER" == "null" ]]; then
    echo "\n===== Error: 'ssh.ssh_user' is missing or null in config.yaml ====="
    exit 1
fi
if [[ -z "$SSH_KEY_PATH" || "$SSH_KEY_PATH" == "null" ]]; then
    echo "\n===== Error: 'ssh.ssh_key_path' is missing or null in config.yaml ====="
    exit 1
fi

# -----------------------------------------------------------------------------
# Check if VM is reachable on SSH port 22 with exponential backoff
# -----------------------------------------------------------------------------
MAX_RETRIES=10
DELAY_SEC=5
MULTIPLIER=2

for ((i = 1; i <= MAX_RETRIES; i++)); do
    echo -e "===== Checking if VM is reachable... Attempt $i of $MAX_RETRIES ====="

    # Check if SSH port 22 is open
    if nc -z -w 5 "$EXTERNAL_IP" 22; then
        echo -e "===== VM is up =====\n"
        break
    fi

    if [[ $i -eq MAX_RETRIES ]]; then
        echo -e "===== VM is still unreachable after $MAX_RETRIES attempts. Exiting. ====="
        exit 1
    fi

    echo -e "===== Waiting for $DELAY_SEC seconds before retrying... ====="
    sleep "$DELAY_SEC"
    DELAY_SEC=$((DELAY_SEC * MULTIPLIER))
done

# -----------------------------------------------------------------------------
# SSH Key Management: Clean stale keys and add new fingerprint
# -----------------------------------------------------------------------------
ssh-keygen -R "$EXTERNAL_IP" 2>/dev/null || true
ssh-keyscan -H "$EXTERNAL_IP" >>~/.ssh/known_hosts 2>/dev/null || {
    echo "\n===== Error: Failed to add $EXTERNAL_IP to known_hosts. ====="
    exit 1
}

# -----------------------------------------------------------------------------
# Ensure the setup_scripts directory exists on the VM and copy setup scripts
# -----------------------------------------------------------------------------
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$EXTERNAL_IP" "mkdir -p ~/setup_scripts"
scp -i "$SSH_KEY_PATH" vm_setup_script.sh "$SSH_USER@$EXTERNAL_IP:~/setup_scripts/"

# -----------------------------------------------------------------------------
# Gather additional configuration values from config.yaml for the remote setup
# -----------------------------------------------------------------------------
GIT_REPO="$(yq e '.github.repo_url' config.yaml)"
GIT_USERNAME="$(yq e '.github.username' config.yaml)"
GIT_EMAIL="$(yq e '.github.email' config.yaml)"
GIT_PAT="$(yq e '.github.personal_access_token' config.yaml)"
PYENV_VERSION="$(yq e '.pyenv.python_version' config.yaml)"

echo -e "\n===== Parameters ====="
echo "SSH User: $SSH_USER"
echo "SSH Key Path: $SSH_KEY_PATH"
echo "GitHub Repo: $GIT_REPO"
echo "GitHub Username: $GIT_USERNAME"
echo "GitHub Email: $GIT_EMAIL"
echo -e "Python Version: $PYENV_VERSION\n"

# -----------------------------------------------------------------------------
# Run the setup script on the VM
# -----------------------------------------------------------------------------
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$EXTERNAL_IP" \
    "chmod +x ~/setup_scripts/vm_setup_script.sh && \
     ~/setup_scripts/vm_setup_script.sh \
         '$GIT_REPO' \
         '$GIT_USERNAME' \
         '$GIT_EMAIL' \
         '$GIT_PAT' \
         '$INSTANCE_NAME' \
         '$PYENV_VERSION'"

# -----------------------------------------------------------------------------
# Display SSH access information to the user
# -----------------------------------------------------------------------------
echo -e "\n===== SSH Command ====="
echo -e "ssh -i $SSH_KEY_PATH $SSH_USER@$EXTERNAL_IP"

echo -e "\n===== SSH Config snippet ====="
cat <<EOF
Host $INSTANCE_NAME
    HostName $EXTERNAL_IP
    User $SSH_USER
    IdentityFile $SSH_KEY_PATH
EOF

exit 0
