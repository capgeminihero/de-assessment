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

# Entra ID groups — looked up as data sources only.
# Groups are owned and created by infra/iam/ (the IAM team module).
# The platform team (this module) references them for Azure RBAC assignments
# but never creates or modifies IAM objects — separation of duties.

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

# 7. Virtual Network
#
# The VNet hosts three subnet tiers:
#   snet-private-endpoints : private endpoints for storage + Databricks UI/API
#   snet-dbx-host          : Databricks host (public) subnet — cluster VMs NIC 1
#   snet-dbx-container     : Databricks container (private) subnet — cluster VMs NIC 2
# Both Databricks subnets are delegated to Microsoft.Databricks/workspaces.
# Azure Databricks auto-manages NSG rules on delegated subnets.
# NAT Gateway provides stable egress IPs (mandatory for new VNets after March 2026).

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

# NSG — Databricks manages required inbound/outbound rules automatically via
# subnet delegation. We create the NSG and associate it; Azure Databricks
# populates the required rules when the workspace is provisioned.
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

# NAT Gateway — required for new VNets after March 31 2026 (Microsoft retired
# default outbound access). Provides stable public egress IPs for cluster nodes
# (TVmaze API calls, library installs, etc.).
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

# 8. Databricks Workspace — Premium, VNet-injected, no public IPs on cluster nodes
#
# VNet injection deploys cluster VMs inside our VNet (snet-dbx-host/container),
# giving them a private path to storage via the private endpoints in snet-private-endpoints.
# Secure Cluster Connectivity (no_public_ip=true) removes public IPs from all
# cluster nodes — traffic flows through the Databricks relay on the backbone.

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
  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "storage_audit" {
  name                       = "diag-${var.project}-storage"
  target_resource_id         = "${azurerm_storage_account.storage.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log { category_group = "allLogs" }
  enabled_metric { category = "Transaction" }
}

# 11. Private Endpoints — Storage Account (blob + dfs)
#
# ADLS Gen2 exposes two sub-resources:
#   - blob: general blob API (used by some SDK paths)
#   - dfs:  Data Lake Storage Gen2 filesystem API (abfss:// uses this)
# Both are needed. Unity Catalog credential vending uses the dfs endpoint.

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

# 12. Private Endpoint — Databricks UI/API (front-end) + Compute Plane (back-end)
#
# With VNet injection, cluster nodes live in our VNet. A single private endpoint
# using subresource "databricks_ui_api" deployed in our VNet covers BOTH:
#   - Front-end: browser/REST API → Databricks control plane
#   - Back-end:  cluster nodes  → Databricks control plane (secure cluster relay)
# All control-plane traffic stays on the Microsoft backbone, never public internet.

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

# Browser authentication endpoint — dedicated PE for browser auth flows.
# Microsoft recommends isolating this for resilience: if the main workspace PE
# is deleted, SSO/browser login still works via this endpoint.
resource "azurerm_private_endpoint" "databricks_auth" {
  name                = "pe-${var.project}-databricks-auth"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  # Must be sequential — concurrent PE creation triggers ConcurrentUpdateError
  # because both try to update the Databricks workspace resource simultaneously.
  depends_on = [azurerm_private_endpoint.databricks_ui_api]

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

# 13. Private DNS Zones
#
# Without DNS zones, clients resolve the storage/Databricks FQDNs to public IPs
# even when a private endpoint exists. These zones override resolution for any
# client linked to the VNet, returning the private IP of the endpoint NIC instead.

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
