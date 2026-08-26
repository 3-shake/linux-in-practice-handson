# linux-in-practice-handson

『［試して理解］Linuxのしくみ 増補改訂版』輪読会のための CTF 風ハンズオン環境。
参加者1人につき1台の Ubuntu 24.04 (x86_64) EC2 を払い出し、章の内容に対応した
問題(フラグ回収・壊れた環境の修復)を仕込んで、手を動かしながら理解を深める。

## 全体像

```
運営                          AWS
────────────────────────────────────────────────────────────
terraform apply ──────▶  EC2 × 参加者数 (Ubuntu 24.04)
                           └ cloud-init が chapters/<章>/setup.sh を実行して問題を仕込む
                         Lambda (採点サーバー・任意)
                           └ 正解すると Slack / Google Chat にお祝いを投稿

参加者
────────────────────────────────────────────────────────────
SSM Session Manager で VM に接続(SSH 鍵・公開ポートなし)
  └ /opt/handson/<章>/ の問題を解いて submit 'flag{...}' で提出
```

- フラグは参加者ごとに `HMAC-SHA256(FLAG_SECRET, "参加者:章-問題")` で決まる。
  コピペによる使い回しはできない
- 採点サーバーがないときは VM 内でローカル採点にフォールバックする
  (VM には正解の sha256 しか置かないため、覗いても答えは分からない)

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `terraform/` | VM 払い出し一式 |
| `chapters/chNN/` | 各章(ch01〜ch12)の問題文(`README.md`)・仕込みスクリプト(`setup.sh`)・自動判定(`check.sh`)・解説(`SOLUTION.md`、実施後公開) |
| `grader/` | 採点 Lambda(VM から Invoke API で直接呼ぶ、Slack / Google Chat の Webhook に通知) |
| `tools/submit` | VM に配布されるフラグ提出コマンド |

## 運営手順

### 払い出し(輪読会の前に)

```console
$ cd terraform
$ cp terraform.tfvars.example terraform.tfvars   # 参加者リストと章を編集
$ export AWS_PROFILE=handson-tf                  # credential_process 経由(下記)
$ export TF_VAR_flag_secret='ランダムな文字列'     # 期間中は同じ値を使い続ける
$ terraform init
$ terraform apply
```

> `aws login` 方式の認証を Terraform は直接読めないため、`~/.aws/config` に
> このプロファイルを用意してある(トークンは実行のたびに自動リフレッシュされる):
>
> ```ini
> [profile handson-tf]
> credential_process = aws configure export-credentials --profile default --format process
> region = ap-northeast-1
> ```

apply 後、接続コマンド一覧を Slack に貼る:

```console
$ terraform output connect_commands
```

参加者はマネジメントコンソール(EC2 → 接続 → セッションマネージャー)からも
接続できる(ローカルに AWS CLI 不要)。

### 接続後のユーザーと権限

- セッションは `ssm-user`(パスワードなし sudo 持ち)で始まり、bash で
  `/opt/handson` に落ちる(SSM セッション設定を Terraform で管理している)
- 実験プログラムの実行は一般ユーザーのまま行い、システムを直す操作
  (`ldconfig`、`chNN-check` など)だけ `sudo` する運用。本の実験スタイルと同じ
- `/opt/handson/<章>/` に問題、`/usr/local/bin/` に `submit`・`chNN-check`、
  `/etc/handson/` に採点用データ(フラグは root のみ読める)

### 答え合わせ

```console
$ terraform output flags
```

### 片付け(輪読会の後)

```console
$ terraform destroy
```

IAM ロール等も消えるが、翌週 apply すれば同名で再作成される。

### 章を進める・追加するとき

1. 新しい章なら `chapters/chNN/` に `README.md`(問題文)・`setup.sh`(仕込み)・
   必要なら `check.sh`(自動判定)を作り、`grader/lambda_function.py` の
   `QUESTIONS` に問題を追加する
2. `terraform.tfvars` の `chapter` を更新する

ch01〜ch12 は作成済み。

| 章 | 問題1(CTF) | 問題2(修復) |
|---|---|---|
| ch01 Linuxの概要 | 捨てられたフラグ | 起動しない greeter |
| ch02 プロセス管理(基礎編) | 眠り続けるデーモン | 倒せないプロセス |
| ch03 プロセススケジューラ | 気難しい預言者 | CPU を譲らない同居人 |
| ch04 メモリ管理システム | 生きているプロセスのメモリ | OOM で死につづけるサービス |
| ch05 プロセス管理(応用編) | 無口な郵便屋 | 消える予約 |
| ch06 デバイスアクセス | 開かずの金庫 | 7年前に巻き戻った業務データ |
| ch07 ファイルシステム | 消えたファイルのフラグ | いっぱいなのに空いている cache |
| ch08 記憶階層 | 幻を映すファイル | 書き込みが遅すぎる |
| ch09 ブロック層 | ディスクに書かれなかったフラグ | 親切すぎるチューナー |
| ch10 仮想化機能 | 消された仮想ディスク | 起動しない仮想マシン |
| ch11 コンテナ | 別世界の金庫 | 1回しか動かないコンテナ |
| ch12 cgroup | 秘密は絞られたときだけ | 何度でも殺されるワーカー |

## 参加者向けルール

- VM の中では何をしてもよい(man・Web 検索も自由)
- ただし `/etc/handson/` を直接読むのは反則(答え合わせ用データ置き場)
- フラグを見つけたら VM 上で `submit 'flag{...}'`

## 設計メモ

- **フラグは Terraform 側で事前計算**(`terraform/scripts/flags.py`、要 python3)して
  VM に渡す。`FLAG_SECRET` を VM に渡さないのは、user-data が IMDS 経由で参加者
  本人に読めるため。漏れて困るのは本人のフラグだけ
  (自分の答えのカンニングは性善説で運用)
- user-data は 16KB 制限。章のファイルが大きくなったら S3 配布に切り替える
- コスト目安: t3.micro × 10人 × 2時間 ≒ 30円/回
