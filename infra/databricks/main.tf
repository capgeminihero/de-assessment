terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
  }
}

# Workspace-level provider — used for all workspace and Unity Catalog resources
provider "databricks" {
  host = var.workspace_url
  # auth via Azure CLI (az login)
}

# Account-level provider — used only for account-level group management
# Authenticates as the terraform-databricks-accounts SP (account admin)
provider "databricks" {
  alias         = "accounts"
  host          = "https://accounts.azuredatabricks.net"
  account_id    = var.databricks_account_id
  azure_client_id     = var.databricks_client_id
  azure_client_secret = var.databricks_client_secret
  azure_tenant_id     = "186c3021-d0e1-4353-b0d9-d9b642e5dd44"
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

# 4. Groups
data "databricks_current_user" "deployer" {}

# Create account-level groups via the accounts provider.
# These are true account-level identities that Unity Catalog accepts as principals.
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

# Assign account-level groups to this workspace so they can be used in notebooks,
# jobs, and Unity Catalog GRANTs.
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

# Catalog-level grants are managed via SQL in the Bronze notebook
# to satisfy assessment requirements for notebook-based access control demonstration.
