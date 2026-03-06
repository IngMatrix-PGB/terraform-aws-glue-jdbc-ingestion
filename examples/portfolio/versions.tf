# ------------------------------------------------------------------------------
# Backend remoto: terraform init -reconfigure -backend-config=backend.hcl
# ------------------------------------------------------------------------------
terraform {
  backend "s3" {
    encrypt = true
  }
}
