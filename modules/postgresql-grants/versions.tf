terraform {
  required_version = ">= 1.9.0"

  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.22, < 2.0"
    }
  }
}
