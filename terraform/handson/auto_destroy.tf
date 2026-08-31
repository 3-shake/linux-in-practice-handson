# ---------------------------------------------------------------
# 自動 destroy の予約(常設側は terraform/ops)
#
# apply のたびに、設定一式の zip を S3 に置き、destroy_at に CodeBuild を
# 起動するワンショットスケジュールを予約する。その terraform destroy で
# zip とスケジュール自身も一緒に消える。
# ---------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  # terraform/ops 側の名前と揃える(バケット名は backend.hcl とも一致させる)
  ops_bucket           = "linux-handson-tfstate-${data.aws_caller_identity.current.account_id}"
  destroy_project_name = "linux-handson-destroy"

  # hh:mm 指定なら apply 当日のその時刻(JST)に展開する。plantimestamp() は
  # UTC を返すので、9 時間足して JST の壁時計に読み替えてから日付部分を取る
  destroy_at = (
    can(regex("^\\d{2}:\\d{2}$", var.destroy_at))
    ? "${formatdate("YYYY-MM-DD", timeadd(plantimestamp(), "9h"))}T${var.destroy_at}:00"
    : var.destroy_at
  )

  # VM の自爆タイマー用(main.tf の runcmd)。destroy_at の 30 分後。
  # formatdate は入力のオフセット(+09:00)を保持したまま整形するので、
  # JST の壁時計時刻のまま systemd-run にタイムゾーン付きで渡せる
  self_destruct_at = "${formatdate("YYYY-MM-DD hh:mm:ss", timeadd("${local.destroy_at}+09:00", "30m"))} Asia/Tokyo"
}

# CodeBuild が destroy に使う設定一式。../chapters や ../tools への参照が
# destroy でも評価される(file() が実在を要求する)ため、リポジトリの
# レイアウトごと固める。tfvars は不要のため除外する(destroy は state の
# 全リソースを消すだけ)
data "archive_file" "destroy_config" {
  type        = "zip"
  source_dir  = "${path.module}/../.."
  output_path = "${path.module}/.terraform/destroy-config.zip"
  excludes = [
    ".git/**",
    "book-text/**",
    "**/*.pdf",
    "**/.DS_Store",
    "**/__pycache__/**",
    "terraform/handson/.terraform/**",
    "terraform/handson/terraform.tfstate",
    "terraform/handson/terraform.tfstate.backup",
    "terraform/handson/*.tfvars",
    "terraform/ops/**",
  ]
}

resource "aws_s3_object" "destroy_config" {
  bucket = local.ops_bucket
  key    = "destroy/config.zip"
  source = data.archive_file.destroy_config.output_path
  etag   = data.archive_file.destroy_config.output_md5
}

# 過去時刻だと apply が失敗する(予約なしで放置される事故の検出を兼ねる)
resource "aws_scheduler_schedule" "destroy" {
  name                         = "linux-handson-destroy"
  schedule_expression          = "at(${local.destroy_at})"
  schedule_expression_timezone = "Asia/Tokyo"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    # CodeBuild はテンプレートターゲット非対応のためユニバーサルターゲット。
    # パラメータ名は API リファレンスの camelCase ではなく PascalCase
    arn      = "arn:aws:scheduler:::aws-sdk:codebuild:startBuild"
    role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/linux-handson-scheduler"
    input    = jsonencode({ ProjectName = local.destroy_project_name })
  }

  # 発火時点で設定 zip が確実に置かれているように
  depends_on = [aws_s3_object.destroy_config]
}
