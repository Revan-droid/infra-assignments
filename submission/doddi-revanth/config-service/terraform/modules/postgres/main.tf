terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
  }
}

variable "namespace"   { type = string }
variable "db_password" { type = string; sensitive = true }

resource "helm_release" "postgres" {
  name       = "postgres"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = "15.5.0"
  namespace  = var.namespace

  set { name = "auth.username";     value = "configuser" }
  set { name = "auth.password";     value = var.db_password; type = "string" }
  set { name = "auth.database";     value = "configdb" }
  set {
    name  = "primary.persistence.size"
    value = "2Gi"
  }
  set {
    name  = "primary.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "primary.resources.requests.memory"
    value = "256Mi"
  }
}

output "postgres_service" {
  value = "postgres-postgresql.${var.namespace}.svc.cluster.local:5432"
}
