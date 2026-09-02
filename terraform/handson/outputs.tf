output "instances" {
  description = "参加者 → インスタンス ID(運営の確認用。接続は Name タグ解決のワンライナーで行う)"
  value       = { for p, i in aws_instance.handson : p => i.id }
}

output "flags" {
  description = "運営用: 人別の正解フラグ一覧(全章分、キーは chNN-qN。terraform output flags で確認)"
  value       = { for p, f in data.external.flags : p => f.result }
  sensitive   = true
}
