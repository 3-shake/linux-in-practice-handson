#!/bin/bash
#
# cloud-init から1回だけ実行される VM の初期化。全章の配布物を S3 から
# 取得して共通コマンドを配置し、今日の章を start-chapter で有効化する。
#
#   DIST_BUCKET=... TODAY_CHAPTER=ch03 AWS_DEFAULT_REGION=... bash bootstrap.sh
#
# 参加者情報(/etc/handson/participant)・フラグ(/etc/handson/flags.env)・
# 採点サーバー ARN は cloud-init の write_files が先に書き込んでいる。
set -euo pipefail

DIST_BUCKET=${DIST_BUCKET:?}
TODAY_CHAPTER=${TODAY_CHAPTER:?}

# Ubuntu 24.04 の apt には awscli パッケージが無いため snap を使う。
# cloud-init の runcmd 時点では snapd の初期化が終わっていないことがあるので待つ
snap wait system seed.loaded
snap install aws-cli --classic

HANDSON=/etc/handson
DIST=$HANDSON/dist
mkdir -p "$DIST"
chmod 755 "$HANDSON"
# 配布物には setup.sh(問題の種明かし)を含むため root 以外には見せない
chmod 700 "$DIST"
# cloud-init の PATH に /snap/bin が入っていないためフルパスで呼ぶ
/snap/bin/aws s3 sync --only-show-errors "s3://$DIST_BUCKET/dist" "$DIST"

install -m 755 "$DIST/tools/submit" /usr/local/bin/submit
install -m 755 "$DIST/tools/vm/start-chapter" /usr/local/bin/start-chapter
install -m 755 "$DIST/tools/vm/handson-status" /usr/local/bin/handson-status
install -m 644 "$DIST/tools/vm/handson-profile.sh" /etc/profile.d/handson.sh

# 章の状態置き場。handson-status が一般ユーザーで読むため 755/644
mkdir -p "$HANDSON/state"
chmod 755 "$HANDSON/state"
ls "$DIST/chapters" >"$HANDSON/state/available"
chmod 644 "$HANDSON/state/available"

start-chapter "$TODAY_CHAPTER"
