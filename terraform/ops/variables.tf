variable "region" {
  description = "AWS リージョン(handson スタックと揃える)"
  type        = string
  default     = "ap-northeast-1"
}

variable "terraform_version" {
  description = "destroy 実行時に CodeBuild が使う Terraform バージョン。ローカルの terraform version と揃える"
  type        = string
  default     = "1.15.8"
}
