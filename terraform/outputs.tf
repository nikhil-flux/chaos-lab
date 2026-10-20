output "kubeconfig_path" {
  description = "Kubeconfig for the kind cluster."
  value       = kind_cluster.this.kubeconfig_path
}

output "next_steps" {
  description = "What to run after the cluster is up."
  value       = "export KUBECONFIG=${kind_cluster.this.kubeconfig_path} && make deploy"
}
