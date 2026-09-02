# ---------------------------------------------------------------
# 自動 destroy の常設インフラ(開催のたびに作り直さないもの)
#
#   S3 バケット      … 両スタックの state + destroy 用設定 zip
#   CodeBuild        … terraform destroy を実行する
#   IAM ロール x2    … CodeBuild 実行用 / EventBridge Scheduler 起動用
#
# ワンショットスケジュール自体は handson スタック側(../handson/auto_destroy.tf)が
# apply のたびに予約する。
# ---------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  bucket_name  = "linux-handson-tfstate-${data.aws_caller_identity.current.account_id}"
  dist_bucket  = "linux-handson-dist-${data.aws_caller_identity.current.account_id}"
  project_name = "linux-handson-destroy"
}

# ---------------------------------------------------------------
# state バケット
# ---------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# state には人別フラグが入るので、古い版をだらだら残さない
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ---------------------------------------------------------------
# 章配布用バケット。中身(オブジェクト)は handson スタックが管理する
# ---------------------------------------------------------------
resource "aws_s3_bucket" "dist" {
  bucket = local.dist_bucket

  # ops を畳むときに handson の残骸オブジェクトで詰まらないように
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "dist" {
  bucket = aws_s3_bucket.dist.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------
# destroy を実行する CodeBuild
# ---------------------------------------------------------------
resource "aws_cloudwatch_log_group" "destroy" {
  name              = "/aws/codebuild/${local.project_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "codebuild" {
  name = "linux-handson-destroy-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# handson スタックが作るリソースを destroy できる最小限
resource "aws_iam_role_policy" "codebuild" {
  name = "destroy-handson-stack"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.destroy.arn}:*"
      },
      {
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation", "s3:GetBucketVersioning"]
        Resource = aws_s3_bucket.tfstate.arn
      },
      {
        Sid    = "StateBucketObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
        ]
        Resource = "${aws_s3_bucket.tfstate.arn}/*"
      },
      {
        # 章配布バケットの中身の削除用(バケット自体は消さない)
        Sid      = "DistBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.dist.arn
      },
      {
        Sid      = "DistBucketObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectTagging", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.dist.arn}/*"
      },
      {
        Sid      = "Ec2Read"
        Effect   = "Allow"
        Action   = "ec2:Describe*"
        Resource = "*"
      },
      {
        Sid    = "Ec2Delete"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteSecurityGroup",
          "ec2:RevokeSecurityGroupEgress",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = "linux-handson" }
        }
      },
      {
        Sid    = "Iam"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:DeleteRole",
          "iam:GetInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/linux-handson-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/linux-handson-*",
        ]
      },
      {
        Sid    = "SsmSessionDocument"
        Effect = "Allow"
        Action = [
          "ssm:DescribeDocument",
          "ssm:GetDocument",
          "ssm:ListTagsForResource",
          "ssm:DescribeDocumentPermission",
          "ssm:DeleteDocument",
        ]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell"
      },
      {
        # 通知用 webhook の取得と、refresh でのパラメータ読み取り用
        Sid      = "SsmParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "*"
      },
      {
        Sid    = "Scheduler"
        Effect = "Allow"
        Action = ["scheduler:GetSchedule", "scheduler:DeleteSchedule"]
        Resource = [
          "arn:aws:scheduler:${var.region}:${data.aws_caller_identity.current.account_id}:schedule/default/linux-handson-*",
        ]
      },
    ]
  })
}

resource "aws_codebuild_project" "destroy" {
  name          = local.project_name
  description   = "handson スタックを terraform destroy する(EventBridge Scheduler が destroy_at に起動)"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TF_VERSION"
      value = var.terraform_version
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.destroy.name
    }
  }

  # ソースは handson スタックが apply のたびに置き直す設定 zip。
  # participants が空でも destroy は state の全リソースを消す
  source {
    type     = "S3"
    location = "${aws_s3_bucket.tfstate.bucket}/destroy/config.zip"

    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        install:
          commands:
            - curl -fsSL -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/$${TF_VERSION}/terraform_$${TF_VERSION}_linux_amd64.zip"
            - unzip -o /tmp/terraform.zip -d /usr/local/bin
            - terraform version
        build:
          commands:
            - cd terraform/handson
            - terraform init -input=false -backend-config=backend.hcl
            - terraform destroy -auto-approve -input=false -var 'participants=[]'
        post_build:
          commands:
            - |
              WEBHOOK=$(aws ssm get-parameter --name /linux-handson/chat-webhook --with-decryption --query Parameter.Value --output text 2>/dev/null || true)
              if [ -n "$WEBHOOK" ]; then
                if [ "$CODEBUILD_BUILD_SUCCEEDING" = "1" ]; then
                  MSG='ハンズオン VM の自動 destroy が完了しました'
                else
                  MSG='ハンズオン VM の自動 destroy が失敗しました。CodeBuild linux-handson-destroy のログを確認してください'
                fi
                curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"text\": \"$MSG\"}" "$WEBHOOK" || true
              fi
    BUILDSPEC
  }
}

# ---------------------------------------------------------------
# EventBridge Scheduler が CodeBuild を起動するためのロール。
# handson スタック側のスケジュール(auto_destroy.tf)が名前参照する
# ---------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "linux-handson-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-destroy-build"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codebuild:StartBuild"
      Resource = aws_codebuild_project.destroy.arn
    }]
  })
}
