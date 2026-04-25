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
  name         = "${var.catalog_name}_${var.environment}"
  storage_root = "abfss://raw@${var.storage_account_name}.dfs.core.windows.net/unity-catalog/${var.environment}"

  depends_on = [databricks_external_location.layers]
}
