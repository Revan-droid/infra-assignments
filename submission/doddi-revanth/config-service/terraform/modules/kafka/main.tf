terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
  }
}

variable "namespace" { type = string }

resource "helm_release" "kafka" {
  name       = "kafka"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "kafka"
  version    = "29.3.3"
  namespace  = var.namespace

  set { name = "replicaCount";                                    value = "1" }
  set { name = "kraft.enabled";                                   value = "true" }
  set { name = "listeners.client.protocol";                       value = "PLAINTEXT" }
  set { name = "persistence.size";                                value = "2Gi" }
  set { name = "resources.requests.cpu";                          value = "200m" }
  set { name = "resources.requests.memory";                       value = "512Mi" }
  set { name = "provisioning.enabled";                            value = "true" }
  set { name = "provisioning.topics[0].name";                     value = "config-events" }
  set { name = "provisioning.topics[0].partitions";               value = "3" }
  set { name = "provisioning.topics[0].replicationFactor";        value = "1" }
}

output "kafka_brokers" {
  value = "kafka.${var.namespace}.svc.cluster.local:9092"
}
