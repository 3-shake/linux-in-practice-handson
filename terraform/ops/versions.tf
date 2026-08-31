terraform {
  # 1.10 以上: S3 backend の use_lockfile(DynamoDB なしのロック)に必要
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }
  }

  # 自己参照(このスタックが作るバケットに自分の state を置く)。初回と
  # 畳むときだけコメントアウトしてローカル state にする(手順は README.md)
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "linux-handson"
    }
  }
}
