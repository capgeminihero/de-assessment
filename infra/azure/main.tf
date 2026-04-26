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

# Entra ID groups — data sources only, created by infra/iam/

data "azuread_group" "dev_team" {
  display_name     = "DE-Dev-Team"
  security_enabled = true
}

data "azuread_group" "compliance_team" {
  display_name     = "Compliance-Team"
  security_enabled = true
}

data "azuread_group" "analyst_team" {
  display_name     = "DA-Analyst-Team"
  security_enabled = true
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

# Storage Blob Data Owner — required for Unity Catalog credential vending (GetUserDelegationKey)

resource "azurerm_role_assignment" "storage_access" {
  scope                = azurerm_storage_account.storage.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
}

# VNet — 3 subnets: private-endpoints, dbx-host, dbx-container

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "dbx_host" {
  name                 = "snet-dbx-host"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "databricks-delegation"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet" "dbx_container" {
  name                 = "snet-dbx-container"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]

  delegation {
    name = "databricks-delegation"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

# NSG — rules auto-populated by Databricks via subnet delegation
resource "azurerm_network_security_group" "dbx" {
  name                = "nsg-${var.project}-dbx"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "dbx_host" {
  subnet_id                 = azurerm_subnet.dbx_host.id
  network_security_group_id = azurerm_network_security_group.dbx.id
}

resource "azurerm_subnet_network_security_group_association" "dbx_container" {
  subnet_id                 = azurerm_subnet.dbx_container.id
  network_security_group_id = azurerm_network_security_group.dbx.id
}

# NAT Gateway — required for outbound internet access (default outbound retired March 2026)
resource "azurerm_public_ip" "nat_gw" {
  name                = "pip-${var.project}-natgw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "main" {
  name                = "natgw-${var.project}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat_gw.id
}

resource "azurerm_subnet_nat_gateway_association" "dbx_host" {
  subnet_id      = azurerm_subnet.dbx_host.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

resource "azurerm_subnet_nat_gateway_association" "dbx_container" {
  subnet_id      = azurerm_subnet.dbx_container.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# Databricks Workspace — Premium, VNet-injected, no public IPs (Secure Cluster Connectivity)

resource "azurerm_databricks_workspace" "this" {
  name                        = "${var.project}-ws"
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = azurerm_resource_group.rg.location
  sku                         = "premium"
  managed_resource_group_name = "${var.project}-dbx-managed"

  custom_parameters {
    no_public_ip                                         = true
    virtual_network_id                                   = azurerm_virtual_network.main.id
    public_subnet_name                                   = azurerm_subnet.dbx_host.name
    private_subnet_name                                  = azurerm_subnet.dbx_container.name
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.dbx_host.id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.dbx_container.id
  }

  depends_on = [
    azurerm_subnet_nat_gateway_association.dbx_host,
    azurerm_subnet_nat_gateway_association.dbx_container,
  ]
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

# Audit logging — Log Analytics sink for Databricks, Key Vault, Storage (90 day retention)

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
  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "storage_audit" {
  name                       = "diag-${var.project}-storage"
  target_resource_id         = "${azurerm_storage_account.storage.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log { category_group = "allLogs" }
  enabled_metric { category = "Transaction" }
}

# Private endpoints — storage blob + dfs (both required for abfss:// and credential vending)

resource "azurerm_private_endpoint" "storage_blob" {
  name                = "pe-${var.project}-storage-blob"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-storage-blob"
    private_connection_resource_id = azurerm_storage_account.storage.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_private_endpoint" "storage_dfs" {
  name                = "pe-${var.project}-storage-dfs"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-storage-dfs"
    private_connection_resource_id = azurerm_storage_account.storage.id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-dfs"
    private_dns_zone_ids = [azurerm_private_dns_zone.dfs.id]
  }
}

# Private endpoint — Databricks UI/API (covers both front-end and cluster relay)

resource "azurerm_private_endpoint" "databricks_ui_api" {
  name                = "pe-${var.project}-databricks-ui-api"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-databricks-ui-api"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-databricks"
    private_dns_zone_ids = [azurerm_private_dns_zone.databricks.id]
  }
}

# Browser authentication endpoint — isolated for resilience
resource "azurerm_private_endpoint" "databricks_auth" {
  name                = "pe-${var.project}-databricks-auth"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  depends_on = [azurerm_private_endpoint.databricks_ui_api] # sequential to avoid ConcurrentUpdateError

  private_service_connection {
    name                           = "psc-databricks-auth"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["browser_authentication"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-databricks-auth"
    private_dns_zone_ids = [azurerm_private_dns_zone.databricks.id]
  }
}

# Private DNS zones — override public FQDN resolution to private endpoint IPs

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "dfs" {
  name                = "privatelink.dfs.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "databricks" {
  name                = "privatelink.azuredatabricks.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "link-blob"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "dfs" {
  name                  = "link-dfs"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dfs.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "databricks" {
  name                  = "link-databricks"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.databricks.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
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
  value = data.azuread_group.dev_team.object_id
}
