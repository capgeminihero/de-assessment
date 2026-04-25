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

variable "catalog_name" {
  description = "Unity Catalog name. Combined with environment to avoid cross-environment collisions."
  type        = string
  default     = "de_assessment"
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}
