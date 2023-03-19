provider "aws" {
  region = var.region # value will be set later in variables.tf

  default_tags {
    tags = {
      ManagedBy = "Terraform"
    }
  }
}
