# Oracle Cloud always-free ARM VM running k3s, bootstrapped by cloud-init with Argo CD pointed at this
# repository on GitHub. The same charts and Argo applications as the local cluster, with envs/oci values.

terraform {
  required_version = ">= 1.9"
  required_providers {
    oci = { source = "oracle/oci", version = "~> 6.0" }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

locals {
  tags = { project = "k8s-platform-gitops", managed_by = "terraform" }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_vcn" "vcn" {
  compartment_id = var.compartment_ocid
  display_name   = "k8s-vcn"
  cidr_blocks    = ["10.50.0.0/16"]
  dns_label      = "k8s"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "k8s-igw"
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "k8s-rt"
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "k8s-sl"
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  # SSH and the Kubernetes API only from the admin address; HTTP and HTTPS from anywhere.
  dynamic "ingress_security_rules" {
    for_each = toset(["22", "6443"])
    content {
      protocol = "6"
      source   = var.admin_cidr
      tcp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }
  dynamic "ingress_security_rules" {
    for_each = toset(["80", "443"])
    content {
      protocol = "6"
      source   = "0.0.0.0/0"
      tcp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }
}

resource "oci_core_subnet" "subnet" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.vcn.id
  display_name      = "k8s-public"
  cidr_block        = "10.50.1.0/24"
  route_table_id    = oci_core_route_table.rt.id
  security_list_ids = [oci_core_security_list.sl.id]
  dns_label         = "pub"
}

resource "oci_core_instance" "node" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "k8s-node"
  shape               = var.shape
  freeform_tags       = local.tags

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }
  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = 150
  }
  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = true
    hostname_label   = "k8s"
  }
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      k3s_version    = var.k3s_version
      argocd_version = var.argocd_chart_version
      repo_url       = var.repo_url
      argocd_values  = file("${path.module}/../../platform/argocd/values.yaml")
      root_app       = file("${path.module}/../../platform/argocd/root-app.yaml")
    }))
  }
}
