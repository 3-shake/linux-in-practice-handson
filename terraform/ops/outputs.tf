output "state_bucket" {
  description = "handson スタックの state バケット。../backend.tf の bucket と一致していることを確認する"
  value       = aws_s3_bucket.tfstate.bucket
}

output "destroy_project" {
  description = "destroy を実行する CodeBuild プロジェクト名(手動実行: aws codebuild start-build --project-name <この値>)"
  value       = aws_codebuild_project.destroy.name
}
