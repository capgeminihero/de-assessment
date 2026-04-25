# Outputs from infra/azure — run: terraform -chdir=infra/azure output
variable "workspace_url" {
  description = "Databricks workspace URL (from azure output)."
  type        = string
}

variable "storage_account_name" {
  description = "ADLS Gen2 storage account name (from azure output)."
  type        = string
}

variable "access_connector_id" {
  description = "Databricks access connector resource ID (from azure output)."
  type        = string
}

variable "managed_identity_id" {
  description = "User-assigned managed identity resource ID (from azure output)."
  type        = string
}

# Databricks PAT — generate in workspace: User Settings → Developer → Access tokens
variable "databricks_token" {
  description = "Databricks personal access token."
  type        = string
  sensitive   = true
}

variable "catalog_name" {
  description = "Unity Catalog name."
  type        = string
  default     = "de_assessment"
}

variable "project" {
  description = "Project name (used for resource naming)."
  type        = string
  default     = "de-assessment"
}
