terraform {
  required_version = ">= 1.8"
}

variable "namespace" {
  description = "Kubernetes namespace for the config service"
  type        = string
  default     = "config-service"
}

variable "db_password" {
  description = "PostgreSQL password (supply via TF_VAR_db_password)"
  type        = string
  sensitive   = true
  default     = ""
}

locals {
  app_name = "config-service"
  common_labels = {
    app        = local.app_name
    managed-by = "terraform"
  }
}

# Placeholder resource that captures bootstrap metadata.
# Replace with kubernetes_namespace, helm_release, etc. as needed.
resource "terraform_data" "bootstrap" {
  input = {
    namespace = var.namespace
    app_name  = local.app_name
  }
}

output "namespace" {
  description = "Namespace the config service is deployed into"
  value       = var.namespace
}
