output "public_ip" {
  value = oci_core_instance.node.public_ip
}

output "kubeconfig_hint" {
  value = "ssh ubuntu@${oci_core_instance.node.public_ip} sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/127.0.0.1/${oci_core_instance.node.public_ip}/' > kubeconfig-oci.yaml"
}

output "argocd_hint" {
  value = "KUBECONFIG=kubeconfig-oci.yaml kubectl -n argocd port-forward svc/argocd-server 8081:80"
}
