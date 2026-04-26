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

# IAM module — sole owner of Entra ID group creation (separation of duties)
# infra/azure and infra/databricks reference groups via data sources only

# DE-Dev-Team — data engineers
resource "azuread_group" "dev_team" {
  display_name     = "DE-Dev-Team"
  security_enabled = true
  mail_enabled     = false
}

# Add deploying user to DE-Dev-Team
resource "azuread_group_member" "deployer" {
  group_object_id  = azuread_group.dev_team.object_id
  member_object_id = data.azuread_client_config.current.object_id
}

# Compliance-Team — read-only access to Bronze for audit/regulatory purposes
resource "azuread_group" "compliance_team" {
  display_name     = "Compliance-Team"
  security_enabled = true
  mail_enabled     = false
}

# DA-Analyst-Team — read-only access to Gold layer
resource "azuread_group" "analyst_team" {
  display_name     = "DA-Analyst-Team"
  security_enabled = true
  mail_enabled     = false
}

# Outputs — referenced by azure + databricks modules

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
