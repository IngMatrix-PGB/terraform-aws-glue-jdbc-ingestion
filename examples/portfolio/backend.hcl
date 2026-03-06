# Backend S3. Reemplazar bucket, key y dynamodb_table por los de tu cuenta.
# Uso: terraform init -reconfigure -backend-config=backend.hcl
bucket         = "TU-BUCKET-TF-STATE"
key            = "matrix-datalake-jdbc-glue/portfolio/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "tu-tabla-lock"
encrypt        = true
