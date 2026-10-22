# The VerteX appliance on AWS with no public subnets, as Terraform: the same resources, names and
# tags as ../create-aws-infra.sh and ../deploy.sh, so ../connect.sh, ../status.sh and
# ../configure.sh work on what this builds. See README.md for the flow.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
  }

  # State is local (terraform.tfstate in this folder) unless you add a backend, for example:
  # backend "s3" {
  #   bucket = "<state-bucket>"
  #   key    = "vertex/<name_prefix>.tfstate"
  #   region = "us-gov-west-1"
  # }
}

provider "aws" {
  region = var.region

  # The deployment tag the scripts find resources by.
  default_tags {
    tags = {
      "vxp:deployment" = var.name_prefix
    }
  }
}
