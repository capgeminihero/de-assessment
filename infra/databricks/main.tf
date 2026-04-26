terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
  }
}

# Workspace provider — auth via Azure CLI
provider "databricks" {
  host = var.workspace_url
}

# Accounts provider — used for account-level group management (SP auth)
provider "databricks" {
  alias               = "accounts"
  host                = "https://accounts.azuredatabricks.net"
  account_id          = var.databricks_account_id
  azure_client_id     = var.databricks_client_id
  azure_client_secret = var.databricks_client_secret
  azure_tenant_id     = "186c3021-d0e1-4353-b0d9-d9b642e5dd44"
}

# Storage credential — links managed identity to Unity Catalog

resource "databricks_storage_credential" "main" {
  name = "sc-${var.project}"
  azure_managed_identity {
    access_connector_id = var.access_connector_id
    managed_identity_id = var.managed_identity_id
  }
}

# External locations — one per medallion layer

resource "databricks_external_location" "layers" {
  for_each        = toset(["raw", "bronze", "silver", "gold"])
  name            = each.key
  url             = "abfss://${each.key}@${var.storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.main.id
}

# Unity Catalog — environment-scoped catalog

resource "databricks_catalog" "main" {
  name          = "${var.catalog_name}_${var.environment}"
  force_destroy = true
  storage_root  = "abfss://bronze@${var.storage_account_name}.dfs.core.windows.net/_catalog_managed/"
  depends_on    = [databricks_external_location.layers]
}

resource "databricks_schema" "bronze" {
  catalog_name = databricks_catalog.main.name
  name         = "bronze"
}

resource "databricks_schema" "silver" {
  catalog_name = databricks_catalog.main.name
  name         = "silver"
}

# Account-level groups — linked to Entra ID via external_id
data "databricks_current_user" "deployer" {}
resource "databricks_group" "dev_team" {
  provider     = databricks.accounts
  count        = var.environment == "dev" ? 1 : 0
  display_name = "DE-Dev-Team"
  external_id  = "baa52807-c988-4c40-88c2-5cc77233c706"
  force        = true
}

resource "databricks_group" "compliance_team" {
  provider     = databricks.accounts
  display_name = "Compliance-Team"
  external_id  = "ad214b15-7987-42f7-abf8-5942e01c93cf"
  force        = true
}

resource "databricks_group" "analyst_team" {
  provider     = databricks.accounts
  display_name = "DA-Analyst-Team"
  external_id  = "71da8424-34c3-4b4e-8fbe-87004d57a729"
  force        = true
}

# Assign groups to this workspace
resource "databricks_mws_permission_assignment" "dev_team" {
  provider     = databricks.accounts
  count        = var.environment == "dev" ? 1 : 0
  workspace_id = 7405605920433807
  principal_id = databricks_group.dev_team[0].id
  permissions  = ["USER"]
}

resource "databricks_mws_permission_assignment" "compliance_team" {
  provider     = databricks.accounts
  workspace_id = 7405605920433807
  principal_id = databricks_group.compliance_team.id
  permissions  = ["USER"]
}

resource "databricks_mws_permission_assignment" "analyst_team" {
  provider     = databricks.accounts
  workspace_id = 7405605920433807
  principal_id = databricks_group.analyst_team.id
  permissions  = ["USER"]
}

# External location grants — dev only

resource "databricks_grants" "developer_external_locations" {
  for_each          = var.environment == "dev" ? databricks_external_location.layers : {}
  external_location = each.value.name

  grant {
    principal  = data.databricks_current_user.deployer.user_name
    privileges = ["READ_FILES", "WRITE_FILES", "CREATE_EXTERNAL_TABLE", "CREATE_MANAGED_STORAGE"]
  }
}

# Pipeline service principal — used by ADF jobs

resource "databricks_service_principal" "pipeline" {
  display_name = "sp-${var.project}-pipeline"
}

# DE-Dev-Team catalog-level grant — inherits SELECT+MODIFY to all current and future tables
resource "databricks_grant" "dev_team_catalog" {
  catalog    = databricks_catalog.main.name
  principal  = "DE-Dev-Team"
  privileges = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "SELECT", "MODIFY"]
}

# Non-authoritative grants for pipeline SP — additive, won't overwrite SQL-managed grants

resource "databricks_grant" "pipeline_catalog" {
  catalog    = databricks_catalog.main.name
  principal  = databricks_service_principal.pipeline.application_id
  privileges = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA"]
}

resource "databricks_grant" "pipeline_bronze" {
  schema     = databricks_schema.bronze.id
  principal  = databricks_service_principal.pipeline.application_id
  privileges = ["USE_SCHEMA", "SELECT", "MODIFY", "CREATE_TABLE"]
  depends_on = [databricks_grant.pipeline_catalog]
}

resource "databricks_grant" "pipeline_silver" {
  schema     = databricks_schema.silver.id
  principal  = databricks_service_principal.pipeline.application_id
  privileges = ["USE_SCHEMA", "SELECT", "MODIFY", "CREATE_TABLE"]
  depends_on = [databricks_grant.pipeline_catalog]
}

# Catalog grants are managed via SQL in the Bronze notebook
