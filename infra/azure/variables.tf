variable "environment" {
  description = "Deployment environment (dev, acc, prod)."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "acc", "prod"], var.environment)
    error_message = "Must be dev, acc, or prod."
  }
}

variable "project" {
  description = "Project name used as a prefix for all resource names."
  type        = string
  default     = "de-assessment"
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "notebook_base_path" {
  description = "Base path in the Databricks workspace where notebooks 01/02/03 are stored (no trailing slash)."
  type        = string
  default     = "/Shared"
}
