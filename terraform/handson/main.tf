data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ---------------------------------------------------------------
# SSM Session Manager 用 IAM(SSH 鍵・公開ポートなしで接続するため)
# ---------------------------------------------------------------
resource "aws_iam_role" "handson" {
  name = "linux-handson-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.handson.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "handson" {
  name = "linux-handson-instance"
  role = aws_iam_role.handson.name
}

# 採点 Lambda は Invoke API で直接呼ぶ(組織ポリシーが Function URL を
# ブロックするため)。submit がインスタンスロールで SigV4 署名する
resource "aws_iam_role_policy" "invoke_grader" {
  count = var.grader_function_arn != "" ? 1 : 0
  name  = "invoke-grader"
  role  = aws_iam_role.handson.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = var.grader_function_arn
    }]
  })
}

# SSM セッションの既定設定(アカウント・リージョン単位)。
# 素の接続だと sh で cwd が agent のディレクトリになり UX が悪いため、
# bash に置き換えて /opt/handson に落とす。
# 注意: 既にセッション設定を保存したことがあるアカウントでは同名ドキュメントが
# 存在して apply が衝突する。その場合は import する:
#   terraform import aws_ssm_document.session_prefs SSM-SessionManagerRunShell
resource "aws_ssm_document" "session_prefs" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "linux handson session preferences"
    sessionType   = "Standard_Stream"
    inputs = {
      idleSessionTimeout = "60"
      # この設定はアカウント・リージョン内の全セッションに効くため、
      # 案内表示はハンズオン VM に限定する(bash -l が読む /etc/profile.d/
      # handson.sh が章の状態を表示する。配置は tools/vm/bootstrap.sh)
      shellProfile = {
        linux = "cd /opt/handson 2>/dev/null; exec /bin/bash -l"
      }
    }
  })
}

# インバウンド全閉。SSM への接続も apt もアウトバウンドのみで成立する
resource "aws_security_group" "handson" {
  name        = "linux-handson"
  description = "linux handson participant VMs (no ingress, SSM only)"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------
# 人別フラグの事前計算(全章分)と、配布物の S3 アップロード
# ---------------------------------------------------------------

# フラグ生成用シークレット(登録手順は ../ops/README.md)。変数で渡さないのは、
# 自動 destroy(CodeBuild)にシークレットを配る経路を作らないため
data "aws_ssm_parameter" "flag_secret" {
  name = "/linux-handson/flag-secret"
}

data "external" "flags" {
  for_each = toset(var.participants)
  program  = ["python3", "${path.module}/scripts/flags.py"]

  query = {
    participant = each.key
    chapters    = jsonencode(local.chapters)
    secret      = data.aws_ssm_parameter.flag_secret.value
    questions   = jsonencode(local.questions)
  }
}

locals {
  # 全章共通の問題ID。フラグは一律 hex 32 文字(flags.py・各章 setup.sh・
  # grader/lambda_function.py の HEX_LEN と揃っている)
  questions = ["q1", "q2"]

  chapters_dir = "${path.module}/../../chapters"

  # 配布対象の全章(setup.sh を持つディレクトリ)。VM には常に全章を配り、
  # どの章を動かすかは VM 上の start-chapter で切り替える
  chapters = sort([for f in fileset(local.chapters_dir, "*/setup.sh") : dirname(f)])

  # 章配布用バケット(../ops 管理)。名前が決定的なので remote state は参照しない
  dist_bucket     = "linux-handson-dist-${data.aws_caller_identity.current.account_id}"
  dist_bucket_arn = "arn:aws:s3:::${local.dist_bucket}"

  # S3 に置く配布物。SOLUTION.md(運営用の解答)と e2e.sh(想定解を含む
  # E2E テスト)は participant の VM から見える場所に置いてはいけない
  dist_files = merge(
    {
      for f in fileset(local.chapters_dir, "**") :
      "chapters/${f}" => "${local.chapters_dir}/${f}"
      if basename(f) != "SOLUTION.md" && basename(f) != "e2e.sh" && !strcontains(f, "__pycache__/") && !endswith(f, ".pyc")
    },
    { "tools/submit" = "${path.module}/../../tools/submit" },
    {
      for f in fileset("${path.module}/../../tools/vm", "*") :
      "tools/vm/${f}" => "${path.module}/../../tools/vm/${f}"
    },
  )
}

resource "aws_s3_object" "dist" {
  for_each = local.dist_files

  bucket      = local.dist_bucket
  key         = "dist/${each.key}"
  source      = each.value
  source_hash = filemd5(each.value)
}

resource "aws_iam_role_policy" "read_dist" {
  name = "read-dist"
  role = aws_iam_role.handson.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.dist_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.dist_bucket_arn}/*"
      },
    ]
  })
}

resource "aws_instance" "handson" {
  for_each = toset(var.participants)

  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = var.instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.handson.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.handson.name

  # 自爆タイマー(runcmd)の poweroff で stop ではなく terminate させる
  instance_initiated_shutdown_behavior = "terminate"

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  # cloud-init: 参加者情報と人別フラグ(全章分)を書き込み、bootstrap.sh が
  # S3 から全章の配布物を取得して今日の章を start-chapter で有効化する。
  # フラグを含むため user-data は IMDS 経由で参加者本人に読めるが、
  # 漏れて困るのは本人のフラグだけ(自分の答えのカンニングは性善説で運用)
  user_data_base64 = base64gzip(join("\n", ["#cloud-config", yamlencode({
    write_files = concat(
      [
        {
          path        = "/etc/handson/participant"
          content     = "${each.key}\n"
          permissions = "0644"
        },
        {
          path = "/etc/handson/flags.env"
          content = join("\n", [
            for k in sort(keys(data.external.flags[each.key].result)) :
            "${k}=${data.external.flags[each.key].result[k]}"
          ])
          permissions = "0600"
        },
        {
          path        = "/opt/handson-bootstrap.sh"
          content     = file("${path.module}/../../tools/vm/bootstrap.sh")
          permissions = "0755"
        },
      ],
      var.grader_function_arn != "" ? [
        {
          path        = "/etc/handson/grader_arn"
          content     = "${var.grader_function_arn}\n"
          permissions = "0644"
        },
      ] : [],
    )
    runcmd = [
      [
        "bash", "-c",
        format(
          "DIST_BUCKET='%s' TODAY_CHAPTER='%s' AWS_DEFAULT_REGION='%s' bash /opt/handson-bootstrap.sh >/var/log/handson-setup.log 2>&1",
          local.dist_bucket,
          var.today_chapter,
          var.region,
        )
      ],
      # 自動 destroy が失敗したときの保険: 予定時刻の 30 分後に self-terminate
      ["systemd-run", "--on-calendar=${local.self_destruct_at}", "systemctl", "poweroff"],
    ]
  })]))
  user_data_replace_on_change = true

  # ブート時の s3 sync が配布物のアップロード前に走らないようにする
  depends_on = [aws_s3_object.dist]

  tags = {
    Name        = "handson-${each.key}"
    Participant = each.key
  }
}
