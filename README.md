# linux-in-practice-handson

『［試して理解］Linuxのしくみ 増補改訂版』輪読会のための CTF 風ハンズオン環境。
参加者1人につき1台の Ubuntu 24.04 (x86_64) EC2 を払い出し、章の内容に対応した
問題(フラグ回収・壊れた環境の修復)を仕込んで、手を動かしながら理解を深める。

## 全体像

```
運営                          AWS
────────────────────────────────────────────────────────────
terraform apply ──────▶  S3 (章の配布物・全12章)
                         EC2 × 参加者数 (Ubuntu 24.04)
                           └ cloud-init が S3 から全章を取得し、
                             「今日の章」(today_chapter)を自動で有効化
                         Lambda (採点サーバー・任意)
                           └ 正解すると Slack / Google Chat にお祝いを投稿

参加者
────────────────────────────────────────────────────────────
SSM Session Manager で VM に接続(SSH 鍵・公開ポートなし)
  ├ /opt/handson/<章>/ の問題を解いて submit 'flag{...}' で提出
  └ start-chapter chNN で章を切り替え(復習・先取りも自由)
```

- フラグは参加者ごとに `HMAC-SHA256(FLAG_SECRET, "参加者:章-問題")` で決まる。
  コピペによる使い回しはできない
- 採点サーバーがないときは VM 内でローカル採点にフォールバックする
  (VM には正解の sha256 しか置かないため、覗いても答えは分からない)
- 章の setup は遅延実行(初回の `start-chapter` 時)。アクティブになるのは
  常に1章だけで、切り替えると前の章は自動で一時停止する(作ったファイルや
  修復の成果は残り、動いている問題プロセスと全体に効く設定だけ戻る)。
  `start-chapter` で戻ればそのまま再開できる

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `terraform/handson/` | VM 払い出し一式(開催ごとに apply、指定時刻に自動 destroy) |
| `terraform/ops/` | 自動 destroy の常設インフラ(state バケット・CodeBuild。初回セットアップ手順も `terraform/ops/README.md`) |
| `chapters/chNN/` | 各章(ch01〜ch12)の問題文(`README.md`)・仕込みスクリプト(`setup.sh`)・自動判定(`check.sh`)・解説(`SOLUTION.md`、実施後公開)。任意で常駐ユニット一覧(`units`)と一時停止・再開フック(`pause.sh` / `resume.sh`) |
| `grader/` | 採点 Lambda(VM から Invoke API で直接呼ぶ、Slack / Google Chat の Webhook に通知) |
| `tools/submit` | VM に配布されるフラグ提出コマンド |
| `tools/vm/` | VM のランタイム一式(cloud-init から呼ばれる `bootstrap.sh`、章切り替えの `start-chapter`、状態表示の `handson-status`、ログイン案内の `handson-profile.sh`) |

## 運営手順

### 払い出し(輪読会の前に)

```console
$ cd terraform/handson
$ cp terraform.tfvars.example terraform.tfvars   # 参加者リストと今日の章を編集
$ export AWS_PROFILE=handson-tf                  # credential_process 経由(下記)
$ terraform init -backend-config=backend.hcl
$ terraform apply
```

初回だけ、フラグ用シークレットの登録と backend.hcl の作成が必要
(`terraform/ops/README.md` 参照)。

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
  `/opt/handson` に落ちる(SSM セッション設定を Terraform で管理している)。
  ログイン時に `handson-status` が章の状態と提出状況を表示する
- 実験プログラムの実行は一般ユーザーのまま行い、システムを直す操作
  (`ldconfig`、`chNN-check` など)だけ `sudo` する運用。本の実験スタイルと同じ
- `/opt/handson/<章>/` に問題、`/usr/local/bin/` に `submit`・`start-chapter`・
  `handson-status`・`chNN-check`、`/etc/handson/` に採点用データと章の配布物
  (フラグと配布物は root のみ読める)
- 章の切り替えは `start-chapter chNN`(初回はその場で setup が走る。
  切り替え時に前の章は自動で一時停止し、進捗は残る)。一時停止中の章の
  ディレクトリに cd すると再開方法を1行案内する(cd で勝手に切り替えはしない)

### 答え合わせ

```console
$ terraform output flags
```

### 章の E2E テスト(任意)

払い出し済みの VM 1台に対して、章の判定(chNN-check)の合否ケースを一通り流す。
対象章を `start-chapter` で有効化し、リポジトリの最新 check.sh を VM に
配置してから、`chapters/chNN/e2e.sh` のシナリオ(不合格系 → 合格系 → 後始末)を
SSM 経由で実行する:

```console
$ tools/e2e ch03            # tag:Name から VM を自動検出(running が1台のとき)
$ tools/e2e ch03 i-xxxx     # インスタンス指定
```

e2e.sh は想定解を含むため、SOLUTION.md と同様に参加者 VM へは配布されない。

### 片付け(輪読会の後)

`destroy_at`(既定: 当日19時 JST)に自動で destroy される。前倒しで消したい
ときは:

```console
$ aws codebuild start-build --project-name linux-handson-destroy   # または terraform destroy
```

IAM ロール等も消えるが、翌週 apply すれば同名で再作成される。

### 章を進める・追加するとき

1. 新しい章なら `chapters/chNN/` に `README.md`(問題文)・`setup.sh`(仕込み)・
   必要なら `check.sh`(自動判定)を作り、`grader/lambda_function.py` の
   `QUESTIONS` に問題を追加する。章が常駐させる systemd ユニットは `units` に
   列挙する(章切り替え時の一時停止・再開の対象)。システム全体に効く設定を
   仕込む章は `pause.sh` / `resume.sh` で退避・復元する(ch08・ch09 参照)
2. `terraform.tfvars` の `today_chapter` を更新する(配布は常に全章)

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
- ただし `/etc/handson/` を直接読むのは反則(答え合わせ用データと
  章の配布物=種明かしの置き場)
- フラグを見つけたら VM 上で `submit 'flag{...}'`
- 今日の章は接続した時点で始まっている。前の章の復習や先取りは
  `start-chapter chNN`(進捗は章ごとに残る)

## 設計メモ

- **フラグは Terraform 側で全章分を事前計算**(`terraform/handson/scripts/flags.py`、
  要 python3)して VM に渡す。`FLAG_SECRET` を VM に渡さないのは、user-data が
  IMDS 経由で参加者本人に読めるため。漏れて困るのは本人のフラグだけ
  (自分の答えのカンニングは性善説で運用)
- **章のファイルは S3 配布**(全12章で user-data の 16KB 制限を超えるため)。
  cloud-init は小さな bootstrap だけを実行し、VM が S3 から
  `/etc/handson/dist/`(root のみ)へ全章を取得する
- **同時にアクティブなのは常に1章**。t3.micro では章同士が干渉するため
  (ch04 の OOM が他章のデーモンを巻き添えにする、ch08 の sysctl 劣化が
  他章の計測を狂わせる、など)。`start-chapter` の切り替えで前の章の
  稼働中ユニットを記録して stop し(`chapters/chNN/units`)、全体に効く knob は
  `pause.sh` / `resume.sh` で退避・復元する。一時停止中の章の `chNN-check` は
  誤判定を避けるため案内スタブに差し替える
- コスト目安: t3.micro × 10人 × 2時間 ≒ 30円/回
