terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
  }
}

provider "databricks" {
  host = var.workspace_url
  # auth via Azure CLI automatically (az login)
}

# 1. Storage Credential — links the managed identity to Unity Catalog
# The managed identity is the only identity that ever touches ADLS directly.
# All user access to storage is mediated through Unity Catalog.

resource "databricks_storage_credential" "main" {
  name = "sc-${var.project}"
  azure_managed_identity {
    access_connector_id = var.access_connector_id
    managed_identity_id = var.managed_identity_id
  }
}

# 2. External Locations — one per medallion layer

resource "databricks_external_location" "layers" {
  for_each        = toset(["raw", "bronze", "silver", "gold"])
  name            = each.key
  url             = "abfss://${each.key}@${var.storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.main.id
}

# 3. Unity Catalog — environment-scoped (de_assessment_dev / acc / prod)

resource "databricks_catalog" "main" {
  name          = "${var.catalog_name}_${var.environment}"
  force_destroy = true
  # Use bronze container as managed storage root (subfolder keeps it separate
  # from actual bronze Delta table data). Bronze external location covers this
  # path and has CREATE_MANAGED_STORAGE granted to the deployer.
  storage_root = "abfss://bronze@${var.storage_account_name}.dfs.core.windows.net/_catalog_managed/"

  depends_on = [databricks_external_location.layers]
}

# 4. Developer group — Entra ID backed (dev only)
#
# "DE-Dev-Team" is created in Microsoft Entra ID by infra/azure/main.tf.
# Azure Databricks (workspaces after Aug 2025) uses Automatic Identity Management
# to continuously mirror Entra ID groups here at the ACCOUNT level.
#
# IMPORTANT: Unity Catalog grants (external locations, catalogs) require
# ACCOUNT-LEVEL principals. A databricks_group created via a workspace-level
# provider is workspace-level only and CANNOT be used in Unity Catalog grants.
# Grants below use data.databricks_current_user.deployer.user_name (account-level)
# until the Entra ID sync creates the account-level DE-Dev-Team group.
# Once synced, replace user_name with "DE-Dev-Team" in all grant principals.

data "databricks_current_user" "deployer" {}

resource "databricks_group" "dev_team" {
  count        = var.environment == "dev" ? 1 : 0
  display_name = "DE-Dev-Team"
  force        = true
}

# 5. Developer Grants (dev only)
# Grants DE-Dev-Team access through Unity Catalog.
# Unity Catalog uses the managed identity for all actual ADLS I/O.
# In acc/prod: environment != "dev" so no grants are created.

resource "databricks_grants" "developer_external_locations" {
  for_each          = var.environment == "dev" ? databricks_external_location.layers : {}
  external_location = each.value.name

  grant {
    principal  = data.databricks_current_user.deployer.user_name
    privileges = ["READ_FILES", "WRITE_FILES", "CREATE_EXTERNAL_TABLE", "CREATE_MANAGED_STORAGE"]
  }
}

# 6. Pipeline Service Principal
# Automated jobs (ADF pipelines, scheduled notebooks) run as this service principal,
# never as a user identity. Prevents production data being overwritten by accident
# if a user account is modified or removed.

resource "databricks_service_principal" "pipeline" {
  display_name = "sp-${var.project}-pipeline"
}

# NOTE: databricks_grants is AUTHORITATIVE — it replaces ALL grants on the resource.
# Both the developer group and pipeline SP must be in a SINGLE resource per object.
# Two separate databricks_grants on the same catalog would overwrite each other.

resource "databricks_grants" "catalog" {
  catalog    = databricks_catalog.main.name
  depends_on = [databricks_group.dev_team]

  dynamic "grant" {
    for_each = var.environment == "dev" ? [1] : []
    content {
      principal  = data.databricks_current_user.deployer.user_name
      privileges = ["USE_CATALOG", "CREATE_SCHEMA", "USE_SCHEMA", "CREATE_TABLE", "SELECT", "MODIFY"]
    }
  }

  grant {
    principal  = databricks_service_principal.pipeline.application_id
    privileges = ["USE_CATALOG", "USE_SCHEMA", "CREATE_TABLE", "SELECT", "MODIFY"]
  }
}
