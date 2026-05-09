resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_resource_quota" "memory" {
  metadata {
    name      = "resource-quota"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    hard = {
      "limits.memory" = var.memory_quota
      "requests.memory" = var.memory_quota
      "requests.cpu"    = "500m"
      "limits.cpu"      = "1000m"
    }
  }
}

resource "kubernetes_secret" "api_token" {
  metadata {
    name      = "api-token"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  data = {
    token = var.api_token
  }

  type = "Opaque"
}
