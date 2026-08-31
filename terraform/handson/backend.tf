# 実値は backend.hcl で渡す: terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
