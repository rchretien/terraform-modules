/*

# Purpose

Create an Azure Batch account [1] with an autoscaling pool of compute nodes that run a Docker
image [2] and can read resource files from a storage account and write the output back to that
storage account.

# Notes

1. Create a storage account [3] for Azure Batch to read resource files and store output files.
2. Create a container within the above-mentioned storage account with a user-tunable retention 
   policy of n days [4].
3. Create the Batch account.
   Warning: it is not possible to create more then a single Batch Account per subscription and per
   region due to quota limitations [5]. Consider contacting Microsoft to increase that if needed.
4. Create a resizable pool with custom autoscaling formula [6] comprised of Docker-compatible
   nodes whose configuration is user-defined [7].
   Warning: by default, only a very limited array of VMs is available (10 VMs chosen amongst the
   Av2 Series, DSv3 Series, Dv3 Series, ESv3 Series and Ev3 Series). Should you need other
   types of VMs or more of them, consider asking for a quota increase for your Azure
   subscription [5].

# Usage

# Create a resource group that gathers all needed resources 
resource "azurerm_resource_group" "batch_computing_rg" {
  name     = "rg-batch-computing-${terraform.workspace}"
  location = "West Europe"
}

module "azure_batch_service" {
  source = "github.com/radix-ai/terraform-modules//azure_batch"
  resource_group_name             = azurerm_resource_group.batch_computing_rg.name
  resource_group_location         = azurerm_resource_group.batch_computing_rg.location
  container_name                  = "inputcontainer"
  keep_inp_files_during_n_days    = 1
  vm_size                         = "Standard_A1_V2"
  container_registry_login_server = "https://my_private_container_registry.com/"
  container_registry_username     = "registry_username"
  container_registry_password     = "registry_password"
  image_name                      = "python"
  image_tag                       = "3.8"
  command_line                    = "echo 'Hello world'"
  autoscale_formula               = <<EOF
          startingNumberOfVMs = 0;
          maxNumberofVMs = 10;
          pendingTaskSamplePercent = $PendingTasks.GetSamplePercent(180 * TimeInterval_Second);
          pendingTaskSamples = pendingTaskSamplePercent < 70 ? startingNumberOfVMs : avg($PendingTasks.GetSample(180 * TimeInterval_Second));
          $TargetDedicatedNodes=min(maxNumberofVMs, pendingTaskSamples);
          $NodeDeallocationOption = taskcompletion;
  EOF
}

# References

[1] https://docs.microsoft.com/en-gb/azure/batch/
[2] https://docs.microsoft.com/en-us/azure/batch/nodes-and-pools
[3] https://docs.microsoft.com/en-us/azure/storage/common/storage-account-overview
[4] https://docs.microsoft.com/en-us/azure/storage/blobs/immutable-time-based-retention-policy-overview
[5] https://docs.microsoft.com/en-us/azure/batch/batch-quota-limit
[6] https://docs.microsoft.com/en-us/azure/batch/batch-automatic-scaling
[7] https://docs.microsoft.com/en-us/azure/batch/batch-docker-container-workloads

*/

# Create an storage account linked to Azure Batch
# See: https://docs.microsoft.com/en-us/azure/batch/accounts
resource "azurerm_storage_account" "batch_computing_s_a" {
  name                     = "batch${terraform.workspace}storage"
  resource_group_name      = var.resource_group_name
  location                 = var.resource_group_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Create a container to store the files related to azure Batch
resource "azurerm_storage_container" "input_files" {
  name                  = var.container_name
  storage_account_name  = azurerm_storage_account.batch_computing_s_a.name
  container_access_type = "private"
}

# Retention policy of 1 day in the previously created container
resource "azurerm_storage_management_policy" "files_retention_duration" {
  storage_account_id = azurerm_storage_account.batch_computing_s_a.id

  rule {
    name    = "delete-older-than-n-days"
    enabled = true
    filters {
      prefix_match = ["${var.container_name}/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.keep_inp_files_during_n_days
      }
      snapshot {
        delete_after_days_since_creation_greater_than = var.keep_inp_files_during_n_days
      }
    }
  }
}

# Create an Azure Batch account
resource "azurerm_batch_account" "batch_account" {
  name                 = "batchaccount${terraform.workspace}"
  resource_group_name  = var.resource_group_name
  location             = var.resource_group_location
  pool_allocation_mode = "BatchService"
  storage_account_id   = azurerm_storage_account.batch_computing_s_a.id
}

# Create the pool within the Azure Batch account
resource "azurerm_batch_pool" "dynamic_pool" {
  name                = "pool-${terraform.workspace}"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_batch_account.batch_account.name
  display_name        = "Time-based autoscaled pool"
  vm_size             = var.vm_size
  node_agent_sku_id   = "batch.node.ubuntu 20.04"

  auto_scale {
    evaluation_interval = "PT5M"

    # Autoscale formula (see: https://docs.microsoft.com/en-us/azure/batch/batch-automatic-scaling)
    formula = var.autoscale_formula
  }

  # Warning: only the 'microsoft-azure-batch' publisher provides Docker-compatible images
  storage_image_reference {
    publisher = "microsoft-azure-batch"
    offer     = "ubuntu-server-container"
    sku       = "20-04-lts"
    version   = "latest"
  }

  container_configuration {
    type = "DockerCompatible"
    container_registries {
      # Put informations about the private container registry here
      registry_server = var.container_registry_login_server
      user_name       = var.container_registry_username
      password        = var.container_registry_password
    }

    # Pull the image stored in the container registry
    container_image_names = ["${var.container_registry_login_server}/${var.image_name}:${var.image_tag}"]
  }
}