import datetime
import os
from google.cloud import compute_v1
from google.oauth2 import service_account
from typing import Union, List, Dict
import time
import logging
import yaml
import json
import sys


class AcquireGpu:
    """
    Class for allocating GPUs on Google Cloud Platform by scanning available zones for
    GPU and machine type availability.

    Helpful references:
        - https://cloud.google.com/compute/resource-usage
        - https://cloud.google.com/compute/docs/gpus
    """

    def __init__(
        self,
        project_id: str,
        vm_name: str,
        gpu_type: str,
        gpu_quota_name: str,
        gpu_count: int,
        machine_types: List[str],
        disk_source_image: str,
        disk_size: int,
    ):
        """
        Initialize AcquireGpu with configuration for GPU allocation.

        Args:
            project_id (str): The GCP project ID.
            vm_name (str): Base name used when creating VMs.
            gpu_type (str): Type of GPU (e.g., 'nvidia-tesla-t4').
            gpu_quota_name (str): The GPU quota metric name (e.g. 'NVIDIA_TESLA_T4_GPUS').
            gpu_count (int): The number of GPUs needed.
            machine_types (List[str]): List of GCE machine types to try (e.g. ['n1-standard-4']).
            disk_source_image (str): The source image to use for the VM's boot disk.
            disk_size (int): Size of the VM's boot disk in GB.
        """
        self.project_id = project_id
        self.vm_name = vm_name
        self.gpu_type = gpu_type
        self.gpu_quota_name = gpu_quota_name
        self.gpu_count = gpu_count
        self.machine_types = machine_types
        self.disk_source_image = disk_source_image
        self.disk_size = disk_size

    def create_single_vm(
        self, region: str, zone_name: str, instance_name: str, machine_type: str
    ) -> Dict[str, str]:
        """
        Attempt to instantiate a single VM instance. Calls the method that constructs
        and sends the InsertInstanceRequest. Logs and returns the status.

        Args:
            region (str): The region derived from the zone (e.g., "us-central1").
            zone_name (str): The zone name (e.g., "us-central1-a").
            instance_name (str): The name for the new VM instance.
            machine_type (str): The machine type to use for the VM.

        Returns:
            Dict[str, str]: Dictionary containing 'region', 'zone', 'instance_name', and 'gpu_reason'.
        """
        try:
            self.create_vm_request(region, zone_name, instance_name, machine_type)
            logging.info(
                f"\nSuccessfully instantiated {self.gpu_type} on {machine_type} "
                f"as {instance_name} VM in {zone_name}\n"
            )
            status = "SUCCESS"
        except Exception as e:
            logging.info(f"{self.gpu_type} failed: {e}\n")
            status = str(e).split(":")[:1][0]

        return {
            "region": region,
            "zone": zone_name,
            "instance_name": instance_name,
            "gpu_reason": status,
        }

    def is_gpu_available(
        self, zone_name: str, accelerator_client: compute_v1.AcceleratorTypesClient
    ) -> bool:
        """
        Check if the specified GPU type is available in a particular zone.

        Args:
            zone_name (str): The zone to check.
            accelerator_client (compute_v1.AcceleratorTypesClient): Client to list accelerator types.

        Returns:
            bool: True if the GPU type is available (and within quota), otherwise False.
        """
        try:
            # List all accelerator types available in this zone
            gpu_request = compute_v1.ListAcceleratorTypesRequest(
                project=self.project_id, zone=zone_name
            )
            gpu_response = list(accelerator_client.list(request=gpu_request))
            gpu_exists = any(gpu.name == self.gpu_type for gpu in gpu_response)

            if not gpu_exists:
                return False

            # Check for GPU resource availability via region quota
            quota_request = compute_v1.GetRegionRequest(
                project=self.project_id, region="-".join(zone_name.split("-")[:-1])
            )
            region_info = compute_v1.RegionsClient().get(request=quota_request)

            # Look for the specific GPU quota
            for quota in region_info.quotas:
                if quota.metric == self.gpu_quota_name:
                    return quota.usage < quota.limit  # GPU is available if usage < limit

            return False

        except Exception as e:
            logging.error(f"Error checking GPU availability in {zone_name}: {e}")
            return False

    def is_machine_available(
        self, zone_name: str, machine_types_client: compute_v1.MachineTypesClient
    ) -> str:
        """
        Check if at least one machine type (from the configured list) is actually
        available in a particular zone by validating machine type existence and CPU quotas.

        Args:
            zone_name (str): The zone to check for machine type availability.
            machine_types_client (compute_v1.MachineTypesClient): Client to check machine types.

        Returns:
            str: The first available machine type if found, otherwise None.
        """
        for machine_type in self.machine_types:
            try:
                machine_request = compute_v1.GetMachineTypeRequest(
                    project=self.project_id, zone=zone_name, machine_type=machine_type
                )
                machine_types_client.get(request=machine_request)  # Will raise if not found

                # Check CPU quota in this zone's region
                quota_request = compute_v1.GetRegionRequest(
                    project=self.project_id, region="-".join(zone_name.split("-")[:-1])
                )
                region_info = compute_v1.RegionsClient().get(request=quota_request)
                for quota in region_info.quotas:
                    # If CPU usage is within limit, consider machine as available
                    if (quota.metric == "CPUS") and (quota.usage < quota.limit):
                        return machine_type
                    else:
                        logging.info(
                            f"Could not find available {machine_type} machine in {zone_name}."
                        )

            except Exception as e:
                logging.error(f"Error checking machine availability in {zone_name}: {e}")

        return None  # No machine available

    def attempt_gpu_allocation(
        self,
        region: str,
        zone,
        machine_types_client: compute_v1.MachineTypesClient,
        gpu_available: bool,
    ) -> Union[bool, Dict[str, str]]:
        """
        If a GPU is marked as available in the given zone, try to find a suitable machine type
        and create a VM instance.

        Args:
            region (str): The region derived from the zone (e.g., 'us-central1').
            zone: The zone object from listing zones.
            machine_types_client (compute_v1.MachineTypesClient): Client to check machine types.
            gpu_available (bool): Indicates whether GPU type is available in this zone.

        Returns:
            (bool, Dict[str, str]):
                - bool: Whether a VM was successfully allocated in this zone.
                - Dict[str, str]: Dictionary of allocation details.
        """
        found_gpu = False
        gpu_allocated = False
        machine_type = None
        instance_name = None
        external_ip = None
        gpu_reason = "UNAVAILABLE"

        if gpu_available:
            machine_type = self.is_machine_available(zone.name, machine_types_client)
            found_gpu = machine_type is not None

        if found_gpu:
            current_timestamp = datetime.datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
            instance_name = f"{self.vm_name}-{current_timestamp}"
            vm_dict = self.create_single_vm(region, zone.name, instance_name, machine_type)

            if vm_dict["gpu_reason"] == "SUCCESS":
                vm_instance = self.start_vm_instance(zone.name, instance_name)
                gpu_allocated = vm_instance is not None
                gpu_reason = "SUCCESS"
                external_ip = self.get_vm_external_ip(self.project_id, zone.name, instance_name)
            else:
                gpu_reason = vm_dict["gpu_reason"]

        return (
            gpu_allocated,
            {
                "region": "-".join(zone.name.split("-")[:-1]),
                "zone": zone.name,
                "instance_name": instance_name,
                "gpu_type": self.gpu_type,
                "machine_type": machine_type,
                "is_available": found_gpu,
                "gpu_allocated": gpu_allocated,
                "gpu_reason": gpu_reason,
                "external_ip": external_ip,
            },
        )

    def scan_zones(self) -> List[Dict]:
        """
        Scan all zones for GPU + machine availability. If a suitable GPU is found,
        this method creates a VM and stops further scanning.

        Returns:
            List[Dict]: A list of dictionaries with allocation details for each zone checked.
        """
        scanned_zones = []
        zones = list(compute_v1.ZonesClient().list(project=self.project_id))
        accelerator_client = compute_v1.AcceleratorTypesClient()
        machine_types_client = compute_v1.MachineTypesClient()

        logging.info(f"{len(zones)} total zones to check.")

        zones_checked = 0
        for zone in zones:
            start = time.time()
            region = "-".join(zone.name.split("-")[:-1])  # e.g. us-central1

            # Check for available GPUs
            gpu_available = self.is_gpu_available(zone.name, accelerator_client)

            # Attempt GPU allocation in this zone
            gpu_allocated, zone_results = self.attempt_gpu_allocation(
                region, zone, machine_types_client, gpu_available
            )
            zone_results["time_to_complete_sec"] = round(time.time() - start, 3)
            scanned_zones.append(zone_results)

            if gpu_allocated:
                logging.info(f"Allocated GPU in {zone.name}.")
                return scanned_zones

            zones_checked += 1
            if zones_checked % 10 == 0:
                logging.info(f"Scanned {zones_checked} zones.")

        allocated_gpu = any(zone["gpu_allocated"] is True for zone in scanned_zones)
        if not allocated_gpu:
            logging.error("No available GPU/machine.")
            sys.exit(1)

        return scanned_zones

    def create_vm_request(
        self, region: str, zone_name: str, instance_name: str, machine_type: str
    ) -> compute_v1.Instance:
        """
        Constructs and sends a request to create a VM instance. Waits for the operation to finish.

        Args:
            region (str): The region derived from the zone.
            zone_name (str): The zone name.
            instance_name (str): Name of the VM instance to create.
            machine_type (str): The machine type to use.

        Returns:
            compute_v1.Instance: The created instance object.
        """
        instance_client = compute_v1.InstancesClient()

        # GPU configuration
        accelerator_config = compute_v1.AcceleratorConfig()
        accelerator_config.accelerator_count = self.gpu_count
        accelerator_config.accelerator_type = (
            f"projects/{self.project_id}/zones/{zone_name}/acceleratorTypes/{self.gpu_type}"
        )

        # Disk configuration
        disk = compute_v1.AttachedDisk(auto_delete=True, boot=True)
        disk.initialize_params = compute_v1.AttachedDiskInitializeParams(
            source_image=self.disk_source_image,
            disk_size_gb=self.disk_size,
            disk_type=f"projects/{self.project_id}/zones/{zone_name}/diskTypes/pd-balanced",
        )

        # Network configuration
        network_interface = compute_v1.NetworkInterface()
        access_config = compute_v1.AccessConfig()
        access_config.name = "External NAT"
        access_config.type_ = "ONE_TO_ONE_NAT"
        network_interface.access_configs = [access_config]
        network_interface.stack_type = "IPV4_ONLY"
        network_interface.subnetwork = (
            f"projects/{self.project_id}/regions/{region}/subnetworks/default"
        )

        # Base instance configuration
        instance = compute_v1.Instance(
            name=instance_name,
            machine_type=f"projects/{self.project_id}/zones/{zone_name}/machineTypes/{machine_type}",
            guest_accelerators=[accelerator_config],
            scheduling=compute_v1.Scheduling(
                automatic_restart=True,
                on_host_maintenance="TERMINATE",
                provisioning_model="STANDARD",
            ),
            disks=[disk],
            network_interfaces=[network_interface],
        )

        request = compute_v1.InsertInstanceRequest()
        request.zone = zone_name
        request.project = self.project_id
        request.instance_resource = instance

        # Execute the create operation and wait until completion
        operation = instance_client.insert(request=request)
        operation.result(timeout=300)

        return instance_client.get(project=self.project_id, zone=zone_name, instance=instance_name)

    def start_vm_instance(self, zone_name: str, instance_name: str) -> str:
        """
        Starts a previously created VM instance. Waits for the operation to finish.

        Args:
            zone_name (str): The zone where the instance resides.
            instance_name (str): The name of the instance to start.

        Returns:
            str: The instance name if started successfully, otherwise None.
        """
        try:
            instance_client = compute_v1.InstancesClient()
            operation = instance_client.start(
                project=self.project_id, zone=zone_name, instance=instance_name
            )
            operation.result(timeout=300)
            started_vm = True
        except Exception as e:
            started_vm = False
            logging.info(f"Failed to start instance {instance_name} (error: {str(e)})")
        return instance_name if started_vm else None

    def delete_vm_instances(self, instantiated_vms: List[Dict]):
        """
        Deletes a list of VMs using their metadata from the 'instantiated_vms' list.

        Args:
            instantiated_vms (List[Dict]): Each dict item must contain:
                - region
                - zone
                - instance_name
                - gpu_type
                - machine_type
                - is_available
                - gpu_allocated
        """
        if not instantiated_vms:
            logging.info("No surplus VMs to delete")
            return

        total_vms = len(instantiated_vms)

        for i, vm_dict in enumerate(instantiated_vms, 1):
            instance_name = vm_dict["instance_name"]
            zone_name = vm_dict["zone"]

            try:
                instance_client = compute_v1.InstancesClient()
                operation = instance_client.delete(
                    project=self.project_id, zone=zone_name, instance=instance_name
                )
                operation.result(timeout=300)
                logging.info(f"\nDeleted {instance_name} from {zone_name}...")
            except Exception as e:
                logging.info(f"\nFailed to delete instance {instance_name} (error: {str(e)})\n")

            # Log progress every time a VM is deleted
            logging.info(f"Progress: {i}/{total_vms} VMs deleted...")

        logging.info("VM deletion process completed.")

    def allocate_gpus(self) -> List[Dict]:
        """
        Allocate GPUs by scanning zones for a matching GPU and machine type. Creates exactly one
        working VM if found (deletes any extra allocations), logs timing, and returns allocated VM(s).

        Returns:
            List[Dict]: List of dictionaries representing allocated VMs, if any.
        """
        start = time.time()

        # Scan all zones for GPU/machine
        scanned_zones = self.scan_zones()

        # Among scanned results, find any VMs that were allocated
        allocated_vms = [vm for vm in scanned_zones if vm["gpu_allocated"] is True]
        successful_allocation = bool(allocated_vms)

        # If multiple VMs are allocated, remove extras
        vms_to_delete = allocated_vms[1:] if len(allocated_vms) > 1 else []
        self.delete_vm_instances(vms_to_delete)

        total_time = round(time.time() - start, 3)

        if successful_allocation:
            logging.info(f"Successfully allocated {self.gpu_type}. Total time: {total_time} sec\n")
        else:
            logging.error(f"Could not allocate {self.gpu_type}. Total time: {total_time} sec\n")
            sys.exit(1)

        return allocated_vms

    def get_vm_external_ip(self, project_id: str, zone: str, instance_name: str) -> str:
        """
        Retrieve the external IP address for an existing VM.

        Args:
            project_id (str): The GCP project ID.
            zone (str): The zone where the instance resides.
            instance_name (str): The name of the instance.

        Returns:
            str: The external IP address if found, otherwise None.
        """
        client = compute_v1.InstancesClient()
        instance = client.get(project=project_id, zone=zone, instance=instance_name)
        for interface in instance.network_interfaces:
            for access_config in interface.access_configs:
                if access_config.name == "External NAT":
                    return access_config.nat_i_p
        return None


def derive_project_id(config_project_id: str) -> str:
    """
    Derive and validate the project ID from service account credentials.

    Args:
        config_project_id (str): Project ID read from config.yaml.

    Raises:
        ValueError: If env var is unset or mismatching project ID.
        FileNotFoundError: If the service account key file is missing.

    Returns:
        str: The verified project ID.
    """
    key_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not key_path:
        raise ValueError("GOOGLE_APPLICATION_CREDENTIALS environment variable is not set.")
    if not os.path.isfile(key_path):
        raise FileNotFoundError(f"Service account key file not found at: {key_path}")

    credentials = service_account.Credentials.from_service_account_file(key_path)
    if not credentials.project_id:
        raise ValueError("The service account credentials do not contain a valid project ID.")
    if credentials.project_id != config_project_id:
        raise ValueError(
            "The service account project ID does not match the config.yaml project ID."
        )
    return credentials.project_id


def main() -> None:
    """
    Main entry point for acquiring a GPU VM. Loads config, validates credentials,
    instantiates AcquireGpu, and attempts GPU allocation.
    """
    # Configure logging
    logging.basicConfig(
        format="%(asctime)s - %(levelname)s - %(message)s",
        level=logging.INFO,
        handlers=[logging.StreamHandler(sys.stdout)],
        force=True,
    )
    logging.info("Start acquiring GPU")

    # Load YAML config
    with open("config.yaml", "r") as f:
        config = yaml.safe_load(f)

    gcp_project_id = derive_project_id(config["gcp"]["project_id"])

    gpu = AcquireGpu(
        project_id=gcp_project_id,
        vm_name=config["gcp"]["vm_name"],
        gpu_type=config["gcp"]["gpu_type"],
        gpu_quota_name=config["gcp"]["gpu_quota_name"],
        gpu_count=config["gcp"]["gpu_count"],
        machine_types=config["gcp"]["machine_types"],
        disk_source_image=config["gcp"]["disk_source_image"],
        disk_size=config["gcp"]["disk_size_gb"],
    )

    # Create VM
    allocated_vms = gpu.allocate_gpus()

    # Added a safety check so we don't index [0] if no VMs were allocated.
    if not allocated_vms:
        logging.error("No VM allocated. Exiting without printing JSON.")
        sys.exit(1)
        return

    output = {
        "GCP_PROJECT_ID": gcp_project_id,
        "ZONE": allocated_vms[0]["zone"],
        "INSTANCE_NAME": allocated_vms[0]["instance_name"],
        "EXTERNAL_IP": allocated_vms[0]["external_ip"],
    }

    # Print JSON output for external use (e.g., in a bash script)
    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
