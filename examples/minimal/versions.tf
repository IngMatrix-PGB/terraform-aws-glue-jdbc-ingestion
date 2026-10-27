terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Exact pin in the root: `init -upgrade` cannot pull an untested release.
      version = "6.60.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = "glue-jdbc-ingestion-example"
      managed-by = "terraform"
    }
  }
}
