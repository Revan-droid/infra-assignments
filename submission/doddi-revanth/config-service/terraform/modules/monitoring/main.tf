terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
  }
}

variable "namespace" { type = string }

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "60.3.0"
  namespace  = var.namespace

  set { name = "grafana.adminPassword";           value = "admin" }
  set { name = "grafana.persistence.enabled";     value = "false" }
  set { name = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"; value = "false" }
  set { name = "alertmanager.enabled";            value = "false" }
}

output "grafana_service" {
  value = "prometheus-grafana.${var.namespace}.svc.cluster.local:80"
}
