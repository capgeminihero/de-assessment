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
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

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

# 2b. Entra ID Security Group — authoritative identity source for Databricks access
#
# "DE-Dev-Team" is created here in Microsoft Entra ID, not inside Databricks.
# Azure Databricks workspaces created after August 2025 use Automatic Identity
# Management: they continuously mirror Entra ID groups into the Databricks account
# with no SCIM token, no enterprise app, and no account_id required.
#
# Membership is managed here. Removing a user from this group in Entra ID
# automatically revokes their Databricks and Unity Catalog access.
# In acc/prod: this block is skipped (count=0). The "DE-Dev-Team" group
# already exists in Entra ID, managed by the IAM team.

resource "azuread_group" "dev_team" {
  count            = var.environment == "dev" ? 1 : 0
  display_name     = "DE-Dev-Team"
  security_enabled = true
  mail_enabled     = false
}

resource "azuread_group_member" "deployer" {
  count            = var.environment == "dev" ? 1 : 0
  group_object_id  = azuread_group.dev_team[0].object_id
  member_object_id = data.azuread_client_config.current.object_id
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

# Unity Catalog managed storage — separate from external data containers.
# External locations cover raw/bronze/silver/gold from their root URLs.
# Databricks rejects a catalog storage_root that overlaps with any external
# location (either as prefix or child path). A dedicated container avoids this.
resource "azurerm_storage_data_lake_gen2_filesystem" "uc_managed" {
  name               = "uc-managed"
  storage_account_id = azurerm_storage_account.storage.id
}

# 6. Role Assignment — Storage Blob Data Owner at storage account scope
#
# Storage Blob Data Owner is required (not Contributor) because Databricks
# Unity Catalog credential vending calls Azure's GetUserDelegationKey API to
# generate short-lived SAS tokens for Spark executors. That API is a storage
# account level operation and requires the generateUserDelegationKey action,
# which is only included in Storage Blob Data Owner, not Contributor.
# Scope must also be at storage account level (not per-container) because
# GetUserDelegationKey is a blobServices-level call, not container-level.

resource "azurerm_role_assignment" "storage_access" {
  scope                = azurerm_storage_account.storage.id
  role_definition_name = "Storage Blob Data Owner"
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

# 10. Audit Logging — Log Analytics Workspace
#
# Centralised sink for all diagnostic logs. Captures:
#   - Databricks: Unity Catalog events, notebook runs, cluster creation, secret access
#   - Key Vault:  every secret read/write/delete operation
#   - Storage:    every blob read/write/delete (who touched what data and when)
# Retention: 90 days (extend to 365+ for regulated industries).
# This is a hard requirement for SOC2, ISO 27001, and GDPR compliance.

resource "azurerm_log_analytics_workspace" "audit" {
  name                = "law-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 90
}

resource "azurerm_monitor_diagnostic_setting" "databricks_audit" {
  name                       = "diag-${var.project}-databricks"
  target_resource_id         = azurerm_databricks_workspace.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log { category_group = "allLogs" }
}

resource "azurerm_monitor_diagnostic_setting" "keyvault_audit" {
  name                       = "diag-${var.project}-kv"
  target_resource_id         = azurerm_key_vault.kv.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log { category_group = "allLogs" }
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage_audit" {
  name                       = "diag-${var.project}-storage"
  target_resource_id         = "${azurerm_storage_account.storage.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log { category_group = "allLogs" }
  metric {
    category = "Transaction"
    enabled  = true
  }
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

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.audit.id
}

output "entra_dev_team_object_id" {
  value = var.environment == "dev" ? azuread_group.dev_team[0].object_id : null
}
