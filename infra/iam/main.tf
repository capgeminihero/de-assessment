terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azuread" {}

data "azuread_client_config" "current" {}

# =============================================================================
# IAM MODULE — Owned by the Identity & Access Management team
#
# This module is the ONLY place Entra ID security groups are created.
# The platform team (infra/azure) and data team (infra/databricks) reference
# these groups via data sources — they never create or modify IAM objects.
#
# Separation of duties:
#   IAM team   → creates groups, manages membership (this module)
#   Platform   → grants Azure RBAC roles to groups (data source lookups only)
#   Data team  → grants Unity Catalog privileges to groups (data source lookups only)
#
# In a real enterprise, this module is in a separate Git repo with its own
# pipeline, requiring IAM team approval for any PR that changes group membership.
# =============================================================================

# DE-Dev-Team — data engineers who build and maintain the medallion pipeline
resource "azuread_group" "dev_team" {
  display_name     = "DE-Dev-Team"
  security_enabled = true
  mail_enabled     = false
}

# Add the deploying user as a member of DE-Dev-Team.
# In production: HR joiner/mover/leaver process drives this via ServiceNow.
resource "azuread_group_member" "deployer" {
  group_object_id  = azuread_group.dev_team.object_id
  member_object_id = data.azuread_client_config.current.object_id
}

# Compliance-Team — regulatory/audit access to Bronze (raw unmodified data)
# Required by GDPR Art. 30 (records of processing), SOX Section 404 (audit trail),
# and ABN AMRO internal data governance policy. Members are assigned by the
# Compliance department, NOT by the DE team.
resource "azuread_group" "compliance_team" {
  display_name     = "Compliance-Team"
  security_enabled = true
  mail_enabled     = false
}

# DA-Analyst-Team — data analysts and BI tools consuming Gold layer output only
# SELECT-only on Gold tables. Never access Bronze or Silver.
# Members are assigned by the Data Analytics chapter lead.
resource "azuread_group" "analyst_team" {
  display_name     = "DA-Analyst-Team"
  security_enabled = true
  mail_enabled     = false
}

# --- Outputs (referenced as data sources by azure + databricks modules) ---

output "dev_team_object_id" {
  value       = azuread_group.dev_team.object_id
  description = "Object ID of DE-Dev-Team in Entra ID"
}

output "compliance_team_object_id" {
  value       = azuread_group.compliance_team.object_id
  description = "Object ID of Compliance-Team in Entra ID"
}

output "analyst_team_object_id" {
  value       = azuread_group.analyst_team.object_id
  description = "Object ID of DA-Analyst-Team in Entra ID"
}
