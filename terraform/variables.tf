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

variable "flag_secret" {
  description = "フラグ生成用シークレット。TF_VAR_flag_secret で渡す。VM には渡らない(人別の計算済みフラグだけが渡る)"
  type        = string
  sensitive   = true
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
