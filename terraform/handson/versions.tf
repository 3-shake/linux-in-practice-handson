terraform {
  # 1.10 以上: S3 backend の use_lockfile(DynamoDB なしのロック)に必要
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4" # 2.4 以上: excludes の glob パターン対応
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "linux-handson"
    }
  }
}
