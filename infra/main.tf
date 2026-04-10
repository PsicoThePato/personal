terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# --- Data sources ---

# Get the latest Ubuntu 22.04 ARM image
data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Get availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# --- Network ---

resource "oci_core_vcn" "kbase" {
  compartment_id = var.compartment_ocid
  display_name   = "kbase-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
}

resource "oci_core_internet_gateway" "kbase" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.kbase.id
  display_name   = "kbase-igw"
}

resource "oci_core_route_table" "kbase" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.kbase.id
  display_name   = "kbase-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.kbase.id
  }
}

resource "oci_core_security_list" "kbase" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.kbase.id
  display_name   = "kbase-sl"

  # Allow SSH
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow all outbound
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "kbase" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.kbase.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "kbase-subnet"
  route_table_id    = oci_core_route_table.kbase.id
  security_list_ids = [oci_core_security_list.kbase.id]
}

# --- Compute ---

resource "oci_core_instance" "kbase" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "kbase-bot"
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.kbase.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
    user_data           = base64encode(file("${path.module}/cloud-init.yaml"))
  }
}

# --- Output ---

output "public_ip" {
  value = oci_core_instance.kbase.public_ip
}
