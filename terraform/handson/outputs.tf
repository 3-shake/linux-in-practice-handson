output "instances" {
  description = "参加者 → インスタンス ID(Slack に貼る用)"
  value       = { for p, i in aws_instance.handson : p => i.id }
}

output "connect_commands" {
  description = "参加者ごとの接続コマンド"
  value = {
    for p, i in aws_instance.handson :
    p => "aws ssm start-session --target ${i.id}"
  }
}

output "flags" {
  description = "運営用: 人別の正解フラグ一覧(全章分、キーは chNN-qN。terraform output flags で確認)"
  value       = { for p, f in data.external.flags : p => f.result }
  sensitive   = true
}
