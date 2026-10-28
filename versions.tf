terraform {
  # >= 1.9: input validations that reference other variables.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Range in the module, exact pin in the root that calls it (see examples/).
      # >= 6.0 for aws_region.region (v6 deprecates name and id).
      version = ">= 6.0, < 7.0"
    }
  }
}
