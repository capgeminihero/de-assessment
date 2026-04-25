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
# Independent of the workspace lifecycle — can be reused across resources.

resource "azurerm_user_assigned_identity" "main" {
  name                = "uai-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# 3. Access Connector for Azure Databricks
# Bridges the Databricks workspace to the managed identity above.
# Required for Unity Catalog to access ADLS Gen2 without secrets.

resource "azurerm_databricks_access_connector" "main" {
  name                = "ac-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.main.id]
  }
}

# 4. Unique Storage Account (ADLS Gen2)

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
  is_hns_enabled           = true # Required for ADLS Gen2 hierarchical namespace
}

# 5. Medallion Architecture Containers

resource "azurerm_storage_data_lake_gen2_filesystem" "layers" {
  for_each           = toset(["raw", "bronze", "silver", "gold"])
  name               = each.key
  storage_account_id = azurerm_storage_account.storage.id
}

# 6. Container-scoped Role Assignments (least privilege)
# FIX: azurerm_storage_data_lake_gen2_filesystem.id returns a DFS URL, not an
# ARM resource ID, which causes the "MissingSubscription" 404 error.
# Use the ARM container path directly instead.

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
# Stores the Databricks PAT so ADF can trigger notebooks without hardcoded secrets.

resource "azurerm_key_vault" "kv" {
  name                      = "kv-${var.project}"
  resource_group_name       = azurerm_resource_group.rg.name
  location                  = azurerm_resource_group.rg.location
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "standard"
  rbac_authorization_enabled = true
}

# 9. Azure Data Factory (Part 4 — pipeline orchestration)
# System-assigned identity is sufficient; ADF only needs to read KV secrets.

resource "azurerm_data_factory" "adf" {
  name                = "adf-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  identity { type = "SystemAssigned" }
}

# Grant ADF identity permission to read secrets from Key Vault.

resource "azurerm_role_assignment" "adf_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

# --- Outputs ---

output "workspace_url" {
  value = azurerm_databricks_workspace.this.workspace_url
}

output "storage_account_name" {
  value = azurerm_storage_account.storage.name
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
