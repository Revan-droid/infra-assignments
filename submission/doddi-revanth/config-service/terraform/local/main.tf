terraform {
  required_version = ">= 1.8"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

# Detect Kind cluster kubeconfig automatically
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-config-service"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kind-config-service"
  }
}

variable "db_password" {
  description = "PostgreSQL password — supply via TF_VAR_db_password or -var flag. Never hardcode."
  type        = string
  sensitive   = true
}

variable "namespace" {
  description = "Kubernetes namespace for the config service"
  type        = string
  default     = "config-service"
}

variable "kafka_brokers" {
  description = "Comma-separated list of Kafka broker addresses"
  type        = string
  default     = "kafka:9092"
}

# ─── Modules ──────────────────────────────────────────────────────────────────

module "app" {
  source = "../modules/app"

  namespace     = var.namespace
  db_password   = var.db_password
  kafka_brokers = var.kafka_brokers
}

module "postgres" {
  source = "../modules/postgres"

  namespace   = var.namespace
  db_password = var.db_password

  depends_on = [module.app]
}

module "kafka" {
  source = "../modules/kafka"

  namespace = var.namespace

  depends_on = [module.app]
}

module "monitoring" {
  source = "../modules/monitoring"

  namespace = var.namespace

  depends_on = [module.app]
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "namespace" {
  description = "Kubernetes namespace"
  value       = var.namespace
}

output "helm_release_name" {
  description = "Helm release name"
  value       = module.app.helm_release_name
}
