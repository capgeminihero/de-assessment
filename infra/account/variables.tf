variable "databricks_account_id" {
  description = "Databricks account UUID."
  type        = string
}

variable "databricks_client_id" {
  description = "Entra ID app (client) ID for the deployer SP — also used as accounts-provider identity."
  type        = string
}

variable "databricks_client_secret" {
  description = "Client secret for the deployer SP."
  type        = string
  sensitive   = true
}

variable "azure_tenant_id" {
  description = "Azure AD tenant ID."
  type        = string
  default     = "186c3021-d0e1-4353-b0d9-d9b642e5dd44"
}

variable "workspace_id" {
  description = "Numeric Databricks workspace ID."
  type        = number
  default     = 7405605920433807
}

variable "pipeline_sp_application_id" {
  description = "Application ID of the Databricks-native pipeline SP."
  type        = string
  default     = "b958d6bb-544e-4ce6-88ee-7567e64380db"
}

variable "project" {
  description = "Project name used for resource naming."
  type        = string
  default     = "de-assessment"
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
