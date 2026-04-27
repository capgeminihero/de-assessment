terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "de-assessment"
    storage_account_name = "deassessmentd06fabcc"
    container_name       = "tfstate"
    key                  = "infra-account/terraform.tfstate"
    use_azuread_auth     = true
  }
}

# Accounts provider — the only provider in this module
# Runs as accounts SP (account admin). No workspace credentials needed here.
provider "databricks" {
  host                = "https://accounts.azuredatabricks.net"
  account_id          = var.databricks_account_id
  azure_client_id     = var.databricks_client_id
  azure_client_secret = var.databricks_client_secret
  azure_tenant_id     = var.azure_tenant_id
}

# ── Deployer SP ────────────────────────────────────────────────────────────────
# The Terraform identity for infra/databricks. Must be registered at account level
# and assigned as workspace ADMIN before the workspace Terraform module can run.

resource "databricks_service_principal" "deployer" {
  application_id = var.databricks_client_id
  display_name   = "sp-${var.project}-deployer"
  force          = true
}

resource "databricks_mws_permission_assignment" "deployer_admin" {
  workspace_id = var.workspace_id
  principal_id = databricks_service_principal.deployer.id
  permissions  = ["ADMIN"]
}

# ── Pipeline SP ────────────────────────────────────────────────────────────────
# Runtime identity. Owns the Unity Catalog and all schemas. Runs ADF jobs.
# Created as a Databricks-native SP (application_id was auto-assigned by Databricks).

resource "databricks_service_principal" "pipeline" {
  application_id = var.pipeline_sp_application_id
  display_name   = "sp-${var.project}-pipeline"
  force          = true
}

resource "databricks_mws_permission_assignment" "pipeline_user" {
  workspace_id = var.workspace_id
  principal_id = databricks_service_principal.pipeline.id
  permissions  = ["USER"]
}

# ── Platform admin group ───────────────────────────────────────────────────────
# Metastore admin identity. Contains only infrastructure/automation SPs.
# Set this group as metastore admin in Account Console > Catalog > metastore_azure_westeurope.

resource "databricks_group" "platform_admins" {
  display_name = "platform-admins"
  force        = true
}

resource "databricks_group_member" "deployer_platform_admin" {
  group_id  = databricks_group.platform_admins.id
  member_id = databricks_service_principal.deployer.id
}

# ── Account-level groups ────────────────────────────────────────────────────────
# Synced from Entra ID via external_id. Assigned to workspace below.

resource "databricks_group" "dev_team" {
  count        = var.environment == "dev" ? 1 : 0
  display_name = "DE-Dev-Team"
  external_id  = "baa52807-c988-4c40-88c2-5cc77233c706"
  force        = true
}

resource "databricks_group" "compliance_team" {
  display_name = "Compliance-Team"
  external_id  = "ad214b15-7987-42f7-abf8-5942e01c93cf"
  force        = true
}

resource "databricks_group" "analyst_team" {
  display_name = "DA-Analyst-Team"
  external_id  = "71da8424-34c3-4b4e-8fbe-87004d57a729"
  force        = true
}

resource "databricks_mws_permission_assignment" "dev_team" {
  count        = var.environment == "dev" ? 1 : 0
  workspace_id = var.workspace_id
  principal_id = databricks_group.dev_team[0].id
  permissions  = ["USER"]
}

resource "databricks_mws_permission_assignment" "compliance_team" {
  workspace_id = var.workspace_id
  principal_id = databricks_group.compliance_team.id
  permissions  = ["USER"]
}

resource "databricks_mws_permission_assignment" "analyst_team" {
  workspace_id = var.workspace_id
  principal_id = databricks_group.analyst_team.id
  permissions  = ["USER"]
}
