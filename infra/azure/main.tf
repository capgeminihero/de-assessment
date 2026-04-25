terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

# 1. Resource Group

resource "azurerm_resource_group" "rg" {
  name     = var.project
  location = var.location
}

# 2. User-Assigned Managed Identity

resource "azurerm_user_assigned_identity" "main" {
  name                = "uai-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# 3. Access Connector for Azure Databricks

resource "azurerm_databricks_access_connector" "main" {
  name                = "ac-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.main.id]
  }
}

# 4. Storage Account (ADLS Gen2)

resource "random_id" "sa" {
  byte_length = 4
}

resource "azurerm_storage_account" "storage" {
  name                     = "${replace(var.project, "-", "")}${random_id.sa.hex}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true
}

# 5. Medallion Architecture Containers

resource "azurerm_storage_data_lake_gen2_filesystem" "layers" {
  for_each           = toset(["raw", "bronze", "silver", "gold"])
  name               = each.key
  storage_account_id = azurerm_storage_account.storage.id
}

# 6. Role Assignments — least privilege per container

resource "azurerm_role_assignment" "storage_access" {
  for_each             = toset(["raw", "bronze", "silver", "gold"])
  scope                = "${azurerm_storage_account.storage.id}/blobServices/default/containers/${each.key}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
}

# 7. Databricks Workspace (premium required for Unity Catalog)

resource "azurerm_databricks_workspace" "this" {
  name                        = "${var.project}-ws"
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = azurerm_resource_group.rg.location
  sku                         = "premium"
  managed_resource_group_name = "${var.project}-dbx-managed"

  custom_parameters {
    no_public_ip = true
  }
}

# 8. Key Vault

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${var.project}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
}

# 9. Azure Data Factory

resource "azurerm_data_factory" "adf" {
  name                = "adf-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  identity { type = "SystemAssigned" }
}

resource "azurerm_role_assignment" "adf_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

# --- Outputs (used as inputs for infra/databricks) ---

output "workspace_url" {
  value = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_id" {
  value = azurerm_databricks_workspace.this.id
}

output "storage_account_name" {
  value = azurerm_storage_account.storage.name
}

output "access_connector_id" {
  value = azurerm_databricks_access_connector.main.id
}

output "managed_identity_id" {
  value = azurerm_user_assigned_identity.main.id
}

output "managed_identity_client_id" {
  value = azurerm_user_assigned_identity.main.client_id
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "adf_name" {
  value = azurerm_data_factory.adf.name
}
