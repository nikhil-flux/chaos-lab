variable "cluster_name" {
  description = "Name of the kind cluster."
  type        = string
  default     = "chaos-lab"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the kind node image."
  type        = string
  default     = "v1.31.0"
}

variable "worker_nodes" {
  description = "Number of kind worker nodes."
  type        = number
  default     = 2
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for Alertmanager notifications."
  type        = string
  sensitive   = true
  default     = "https://hooks.slack.com/services/T000/B000/REPLACE_ME"
}

variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  sensitive   = true
  default     = "chaos-admin"
}

variable "chaos_mesh_chart_version" {
  description = "Chaos Mesh Helm chart version. Null installs the latest; pin it once things work."
  type        = string
  default     = null
}

variable "prometheus_stack_chart_version" {
  description = "kube-prometheus-stack Helm chart version. Null installs the latest; pin it once things work."
  type        = string
  default     = null
}
