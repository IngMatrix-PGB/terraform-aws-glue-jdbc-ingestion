# Ejemplo reproducible (Secrets Manager → connection_properties)

Credenciales JDBC en **AWS Secrets Manager**: `data "aws_secretsmanager_secret_version"` → locals → **connection_properties**. Sin credenciales en código ni en tfvars.

## Flujo

1. Secret en AWS con valor JSON: `{"username": "tu_usuario", "password": "tu_password"}`.
2. `data.tf`: `data "aws_secretsmanager_secret_version" "jdbc"` (por nombre o ARN).
3. `locals.tf`: `jdbc_credentials = jsondecode(...)` y `connection_props_postgres` / `connection_props_mysql` con `USERNAME` y `PASSWORD` del secret.
4. `main.tf`: cada `module "matrix-datalake-jdbc-glue"` recibe `connection_properties = local.connection_props_*`.

## Cómo ejecutar

```bash
cd examples/portfolio

# Backend (opcional; editar backend.hcl con tu bucket/key)
terraform init -reconfigure -backend-config=backend.hcl

# Plan y apply
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

En `terraform.tfvars` define al menos `jdbc_secret_name` o `jdbc_secret_arn`, más `subnet_id`, `security_group_ids`, `scripts_bucket`, `jdbc_host_postgres`, `jdbc_host_mysql`.

## Escalabilidad

- **Más fuentes JDBC**: en `locals.tf` añade `connection_props_*` y en `main.tf` otro `module "jdbc_*"`.
- **Más ambientes**: copia `terraform.tfvars` y `backend.hcl` a nombres tipo `terraform.prd.tfvars` y `backend-prd.hcl` y usa los que correspondan.
