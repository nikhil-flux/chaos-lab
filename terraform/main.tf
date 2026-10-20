resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = "kindest/node:${var.kubernetes_version}"
  kubeconfig_path = "${path.module}/${var.cluster_name}-kubeconfig"
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
    }

    dynamic "node" {
      for_each = range(var.worker_nodes)

      content {
        role = "worker"
      }
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.this.endpoint
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
  }
}

provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
}

# Chaos Mesh: the fault-injection engine.
resource "helm_release" "chaos_mesh" {
  name             = "chaos-mesh"
  repository       = "https://charts.chaos-mesh.org"
  chart            = "chaos-mesh"
  version          = var.chaos_mesh_chart_version
  namespace        = "chaos-mesh"
  create_namespace = true
  wait             = true
  timeout          = 600

  # kind nodes run containerd.
  set {
    name  = "chaosDaemon.runtime"
    value = "containerd"
  }

  set {
    name  = "chaosDaemon.socketPath"
    value = "/run/containerd/containerd.sock"
  }

  # Lab only: no login on the Chaos Mesh dashboard.
  set {
    name  = "dashboard.securityMode"
    value = "false"
  }

  depends_on = [kind_cluster.this]
}

# Prometheus + Alertmanager + Grafana + kube-state-metrics.
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.prometheus_stack_chart_version
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [file("${path.module}/../monitoring/values-prometheus.yaml")]

  set_sensitive {
    name  = "alertmanager.config.global.slack_api_url"
    value = var.slack_webhook_url
  }

  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  depends_on = [kind_cluster.this]
}

# The Grafana sidecar loads any ConfigMap labelled grafana_dashboard=1.
resource "kubernetes_config_map" "grafana_dashboard" {
  metadata {
    name      = "chaos-lab-dashboard"
    namespace = "monitoring"

    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "chaos-lab.json" = file("${path.module}/../monitoring/grafana-dashboard.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
