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

variable "environment" {
  description = "Deployment environment (dev, acc, prod)."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "acc", "prod"], var.environment)
    error_message = "Must be dev, acc, or prod."
  }
}

variable "catalog_name" {
  description = "Base Unity Catalog name — environment is appended automatically."
  type        = string
  default     = "de_assessment"
}

variable "project" {
  description = "Project name (used for resource naming)."
  type        = string
  default     = "de-assessment"
}

variable "databricks_account_id" {
  description = "Databricks account UUID (from accounts.azuredatabricks.net)."
  type        = string
}

variable "databricks_client_id" {
  description = "Entra ID app (client) ID for the Terraform accounts service principal."
  type        = string
}

variable "databricks_client_secret" {
  description = "Client secret for the Terraform accounts service principal."
  type        = string
  sensitive   = true
}



