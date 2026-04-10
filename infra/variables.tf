variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
}

variable "user_ocid" {
  description = "OCI user OCID"
}

variable "fingerprint" {
  description = "OCI API key fingerprint"
}

variable "private_key_path" {
  default = "~/.oci/oci_api_key.pem"
}

variable "region" {
  default = "sa-saopaulo-1"
}

variable "compartment_ocid" {
  description = "OCI compartment OCID"
}

variable "ssh_public_key_path" {
  default = "~/.ssh/id_ed25519.pub"
}
