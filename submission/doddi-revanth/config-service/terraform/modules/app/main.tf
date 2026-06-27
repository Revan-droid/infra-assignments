terraform {
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

variable "namespace" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "kafka_brokers" {
  type    = string
  default = "kafka:9092"
}

# ─── Namespace ────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "local"
    }
  }
}

# ─── Database Secret ──────────────────────────────────────────────────────────
resource "kubernetes_secret" "db" {
  metadata {
    name      = "config-service-db"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  type = "Opaque"
  data = {
    DATABASE_URL = "postgres://configuser:${var.db_password}@postgres.${var.namespace}.svc.cluster.local:5432/configdb?sslmode=disable"
  }
}

# ─── Kafka Secret ─────────────────────────────────────────────────────────────
resource "kubernetes_secret" "kafka" {
  metadata {
    name      = "config-service-kafka"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  type = "Opaque"
  data = {
    KAFKA_BROKERS = var.kafka_brokers
  }
}

# ─── Helm Release ─────────────────────────────────────────────────────────────
resource "helm_release" "config_service" {
  name       = "config-service"
  chart      = "${path.module}/../../deployments/helm/config-service"
  namespace  = kubernetes_namespace.this.metadata[0].name
  wait       = true
  timeout    = 300

  set {
    name  = "config.enableKafka"
    value = "false"
  }

  depends_on = [
    kubernetes_secret.db,
    kubernetes_secret.kafka,
  ]
}

output "helm_release_name" {
  value = helm_release.config_service.name
}
