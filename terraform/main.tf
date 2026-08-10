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
      # 案内表示はハンズオン VM(/opt/handson がある)に限定する
      shellProfile = {
        linux = "cd /opt/handson 2>/dev/null && echo '問題文: cat /opt/handson/ch*/README.md'; exec /bin/bash -l"
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
# 人別フラグの事前計算と、章のファイル一式の cloud-init への埋め込み
# ---------------------------------------------------------------
data "external" "flags" {
  for_each = toset(var.participants)
  program  = ["python3", "${path.module}/scripts/flags.py"]

  query = {
    participant = each.key
    chapter     = var.chapter
    secret      = var.flag_secret
    questions   = jsonencode(var.questions)
  }
}

locals {
  chapter_dir = "${path.module}/../chapters/${var.chapter}"

  # 章のファイル + submit コマンドを /opt/src 以下に同じ構造で配置する。
  # SOLUTION.md(運営用の解答)は participant の VM に配布してはいけない
  payload_files = merge(
    {
      for f in fileset(local.chapter_dir, "**") :
      "chapters/${var.chapter}/${f}" => "${local.chapter_dir}/${f}"
      if f != "SOLUTION.md"
    },
    { "tools/submit" = "${path.module}/../tools/submit" },
  )

  # gzip 圧縮で user-data の 16KB 制限に余裕を持たせる。
  # file() の制約でテキストファイル前提(バイナリを配りたくなったら S3 へ)
  write_files = [
    for rel, abs in local.payload_files : {
      path        = "/opt/src/${rel}"
      encoding    = "gz+b64"
      content     = base64gzip(file(abs))
      permissions = "0644"
    }
  ]
}

resource "aws_instance" "handson" {
  for_each = toset(var.participants)

  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = var.instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.handson.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.handson.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  # cloud-init: ファイルを書き込み、人別フラグを渡して章の setup.sh を実行。
  # 注意: user-data は 16KB 制限。章の payload が肥大したら S3 配布に切り替える
  user_data = join("\n", ["#cloud-config", yamlencode({
    write_files = local.write_files
    runcmd = [[
      "bash", "-c",
      format(
        "PARTICIPANT='%s' %s GRADER_URL='%s' bash /opt/src/chapters/%s/setup.sh >/var/log/handson-setup.log 2>&1",
        each.key,
        join(" ", [
          for qid in sort(keys(var.questions)) :
          "FLAG_${upper(qid)}='${data.external.flags[each.key].result[qid]}'"
        ]),
        var.grader_url,
        var.chapter,
      )
    ]]
  })])
  user_data_replace_on_change = true

  tags = {
    Name        = "handson-${var.chapter}-${each.key}"
    Participant = each.key
  }
}
