# 常設インフラ（自動 destroy・章配布バケット）

開催日の `destroy_at`（既定: 当日 19 時 JST）に参加者 VM を自動で片付ける
ためのリソースと、章配布用の S3 バケット（`linux-handson-dist-<account>`。
中身は handson 側が apply で同期し destroy で消す）。毎回の払い出しは
従来どおりローカルから `terraform/handson/` を apply する。state バケット名などの実値は
各ディレクトリの `backend.hcl`（アカウント ID を含むため gitignore 済み。
`backend.hcl.example` からコピーして作る）。

```
朝:         ローカルで terraform apply
              ├─ 参加者 VM などを作成
              ├─ 設定一式の zip を S3 に配置
              └─ EventBridge Scheduler にワンショット予約
destroy_at: Scheduler → CodeBuild(linux-handson-destroy)が terraform destroy
              └─ VM・スケジュール・zip ごと全部消える
保険:       destroy が失敗しても、VM 自身が destroy_at+30分 に self-terminate
```

## 初回セットアップ

1. フラグ生成用シークレットを Parameter Store に登録する（一度だけ。
   これ以降 `TF_VAR_flag_secret` は不要）:

   ```sh
   aws ssm put-parameter --name /linux-handson/flag-secret \
     --type SecureString --value '<シークレット>'
   ```

   あわせて、このディレクトリと `../handson` の両方で `backend.hcl` を
   用意する:

   ```sh
   sed 's/<AWS_ACCOUNT_ID>/<アカウントID>/' backend.hcl.example > backend.hcl
   ```

2. state バケットがまだないので、`versions.tf` の backend ブロックを
   **一時的にコメントアウト**してローカル state で apply する
   （state バケット・CodeBuild・IAM ができる）:

   ```sh
   terraform init && terraform apply
   ```

   output の `state_bucket` が `backend.hcl`・`../handson/backend.hcl` の
   `bucket` と一致することを確認。

3. backend ブロックのコメントアウトを戻し、ops の state を S3 に移す
   （git 差分がない状態が定常）:

   ```sh
   terraform init -backend-config=backend.hcl -migrate-state
   ```

4. handson スタックの state も S3 に移す:

   ```sh
   cd ../handson && terraform init -backend-config=backend.hcl -migrate-state
   ```

5. （任意）destroy の成否を Google Chat に通知する場合は webhook を登録:

   ```sh
   aws ssm put-parameter --name /linux-handson/chat-webhook \
     --type SecureString --value '<webhook URL>'
   ```

## 開催日ごとの運用

- `terraform.tfvars` の `participants`・`chapter` を更新して apply するだけ。
  destroy は **既定で当日 19 時（JST）** に予約される。
- 時刻を変えたい日だけ `destroy_at` を指定する（tfvars か `-var`）。
  `"18:30"` なら当日のその時刻、`"2026-09-02T21:00:00"` なら指定日時。
  当日の予約時刻を過ぎてから再 apply する場合も、過去時刻でスケジュール
  作成に失敗するので `destroy_at` で先の時刻を明示する。
- destroy_at に自動で destroy される（参加者のセッションは強制切断される）。
- 動作確認や前倒しで消したいときは手動で起動してよい:

  ```sh
  aws codebuild start-build --project-name linux-handson-destroy
  ```

## 全部を畳むとき（輪読会の終了時）

state バケットは自分の state の置き場でもあるので、destroy の前にローカルへ
戻す。

1. handson スタックが destroy 済みであることを確認する
   （`cd ../handson && terraform state list` が空）。
2. `versions.tf` の backend ブロックを一時的にコメントアウトして state を
   ローカルへ:

   ```sh
   terraform init -migrate-state
   ```

3. バケットはバージョニング有効で中身（旧 state など）が残っているため、
   `aws_s3_bucket.tfstate` に一時的に `force_destroy = true` を付けて
   apply してから destroy する:

   ```sh
   terraform apply && terraform destroy
   ```

## 注意

- handson スタックに新しい種類のリソースを足したら、`main.tf` の
  CodeBuild ロールのポリシーにも destroy に必要な権限を足すこと。
- CodeBuild が使う Terraform のバージョンは `var.terraform_version`。
  ローカルを上げたらここも揃える。
