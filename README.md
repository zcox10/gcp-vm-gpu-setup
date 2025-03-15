# GCP GPU Acquisition and VM Setup

This repository contains scripts that automate the process of acquiring a GPU-enabled VM on Google Cloud Platform (GCP) and then configuring that VM for development. The automation includes installing CUDA drivers, validating the CUDA installation, setting up Git and SSH keys, cloning a GitHub repository, and establishing a Python environment using `pyenv`. The entire process is highly modular and configurable via the `config.yaml` file.

## Overview

The automation workflow is divided into three main parts:

1. **GPU Acquisition on GCP**  
   The `create_gcp_vm_instance.py` script scans available GCP zones for a GPU-enabled machine based on your configuration and creates a VM instance. It outputs JSON with details like the project ID, zone, instance name, and external IP address.

2. **Remote VM Setup via SSH**  
   The `start.sh` script orchestrates the process by:
   - Running the Python script to acquire the VM.
   - Waiting until the VM is reachable over SSH.
   - Copying the `vm_setup_script.sh` to the VM.
   - Remotely executing the setup script to install CUDA, validate the CUDA installation, install Git, configure SSH keys for GitHub, clone the specified repository, and set up a Python environment with `pyenv`.

3. **Local VM Access**  
   After the remote setup, SSH connection details and a sample SSH configuration snippet are displayed so you can easily connect to the VM.

## Configuration

All the major parameters for the setup are defined in the `config.yaml` file. This modular file lets you adjust settings for GCP, GitHub, SSH, and the Python environment without modifying the scripts.

## Configuration Details

- GCP Settings:
  - `project_id`: The Google Cloud project identifier.
  - `gpu_count`: Number of GPUs to allocate.
  - `disk_source_image`: The image to be used for the VM's boot disk.
  - `disk_size_gb`: Size (in GB) of the VM's boot disk.
  - `vm_name`: Base name for the VM instance.
  - `gpu_type`: Type of GPU to be allocated.
  - `gpu_quota_name`: Quota metric for the specified GPU type.
  - `machine_types`: List of machine types to try when allocating the VM.

- GitHub Settings:
  - `repo_url`: The repository URL to be cloned on the VM.
  - `username`: Your GitHub username.
  - `email`: Your GitHub email.
  - `ssh_key_path`: Path to the SSH key used for GitHub access.
  - `personal_access_token`: GitHub personal access token for API interactions (e.g., uploading SSH keys).

- SSH Settings:
  - `ssh_user`: The username for SSH access on the VM.
  - `ssh_key_path`: The path to the SSH key for accessing the VM.

- Python Environment:
  - `python_version`: The Python version to install using pyenv.

## Script Descriptions

`create_gcp_vm_instance.py`

- **Purpose**: Scans GCP zones to locate a suitable GPU-enabled VM based on the configuration and creates the VM.
- **Key Actions**:
  - Scans available zones for the specified GPU and machine type.
  - Creates a VM instance and starts it.
  - Retrieves and outputs the external IP and other VM details as JSON.

`start.sh`

- **Purpose**: Orchestrates the entire setup process.
- **Key Actions**:
  - Executes `create_gcp_vm_instance.py` to acquire a GPU-enabled VM.
  - Validates the output and waits until the VM is reachable over SSH (using exponential backoff).
  - Copies the `vm_setup_script.sh` to the VM.
  - Remotely runs the VM setup script.
  - Displays SSH connection details and a sample SSH config snippet.

`vm_setup_script.sh`

- **Purpose**: Runs on the allocated VM to set up the development environment.
- **Key Actions**:
  - Updates and upgrades the system.
  - Installs CUDA drivers and validates the installation using a sample CUDA application.
  - Installs Git and configures SSH keys for GitHub access.
  - Clones the GitHub repository specified in `config.yaml`.
  - Installs `pyenv` and sets up a Python virtual environment.
  - Cleans up unnecessary files post-setup.

## Process Flow

- **GPU Acquisition**
  - The process starts with `start.sh` executing `create_gcp_vm_instance.py`. The Python script scans GCP zones for available GPUs and machine types, allocates a VM if possible, and returns details such as the external IP.
- **Remote VM Setup**
  - `start.sh` then waits until the new VM is reachable over SSH. Once reachable, it copies the `vm_setup_script.sh` to the VM and runs it. The remote setup script installs and configures the CUDA toolkit, validates the installation, sets up Git and SSH keys, clones a pre-defined repository, and configures a Python environment.
- **Access and Verification**
  - After the remote setup completes, the scripts provide the necessary SSH commands and configuration snippets to allow you to connect to the VM for further development.

## Usage

- **Prepare Configuration**: update the `config.yaml` file with your GCP, GitHub, SSH, and Python environment parameters.
- **Run the Orchestration Script**: execute the `start.sh` script:

```bash
./start.sh
```

- **Follow On-Screen Instructions**: Monitor the console output to ensure that the GPU is acquired and the VM is successfully set up.
- **Connect to the VM**: Use the displayed SSH command or SSH configuration snippet to log into your newly configured VM.

## Modular Configuration

All key parameters are defined in the config.yaml file, making the setup highly modular:

- **GCP Section:**
  - Adjust parameters like `project_id`, `gpu_count`, `disk_source_image`, `disk_size_gb`, `vm_name`, `gpu_type`, `gpu_quota_name`, and `machine_types` to tailor the VM provisioning.
- **GitHub Section:**
  - Specify the repository URL, username, email, SSH key path, and personal access token to manage repository cloning and SSH key uploads.
- **SSH Section:**
  - Set the SSH username and key path for VM access.
- **pyenv Section:**
  - Define the Python version to install, allowing you to customize the development environment with `pyenv`.

## Conclusion

This automation framework streamlines the process of acquiring a GPU-enabled VM on GCP and setting it up for development with CUDA, Git, and a Python environment. By leveraging the modular configuration in `config.yaml`, you can easily adapt the setup to different projects or environments with minimal changes to the underlying scripts.
