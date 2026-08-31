variable "region" {
  description = "AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "chapter" {
  description = "払い出す章 (chapters/ 以下のディレクトリ名)"
  type        = string
  default     = "ch01"
}

variable "participants" {
  description = "参加者名のリスト。1人につき VM が1台立つ"
  type        = list(string)
}

variable "destroy_at" {
  description = "自動 destroy の時刻(JST)。hh:mm なら apply 当日のその時刻、YYYY-MM-DDThh:mm:ss なら指定日時。この時刻に EventBridge Scheduler が CodeBuild(terraform/ops 参照)を起動して terraform destroy する"
  type        = string
  default     = "19:00"

  validation {
    condition = (
      can(regex("^\\d{2}:\\d{2}$", var.destroy_at)) ||
      can(regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}$", var.destroy_at))
    )
    error_message = "destroy_at は hh:mm(apply 当日) か YYYY-MM-DDThh:mm:ss(JST)で指定する。"
  }
}

variable "instance_type" {
  description = "参加者 VM のインスタンスタイプ"
  type        = string
  default     = "t3.micro"
}

variable "grader_function_arn" {
  description = "採点 Lambda の ARN(自動お祝い用・未デプロイなら空のまま)。組織ポリシーで公開 Function URL が使えないため、submit がインスタンスロールの SigV4 署名で Invoke API を直接呼ぶ"
  type        = string
  default     = ""
}
