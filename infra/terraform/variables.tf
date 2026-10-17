variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "fingerprint" { type = string }
variable "private_key_path" { type = string }
variable "compartment_ocid" { type = string }

variable "region" {
  type    = string
  default = "us-ashburn-1"
}

variable "shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  type    = number
  default = 4
}

variable "memory_gb" {
  type    = number
  default = 24
}

variable "ssh_public_key" { type = string }

variable "admin_cidr" {
  description = "CIDR allowed to SSH and to reach the Kubernetes API"
  type        = string
}

variable "k3s_version" {
  type    = string
  default = "v1.33.4+k3s1"
}

variable "argocd_chart_version" {
  type    = string
  default = "8.3.0"
}

variable "repo_url" {
  description = "The GitOps repository Argo CD follows"
  type        = string
  default     = "https://github.com/Tajaddin/k8s-platform-gitops.git"
}
