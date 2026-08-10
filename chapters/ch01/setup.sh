#!/bin/bash
#
# 第1章ハンズオンの環境セットアップ(root で実行、cloud-init から呼ばれる想定)
#
#   PARTICIPANT=alice FLAG_Q1='flag{...}' FLAG_Q2='flag{...}' ./setup.sh   # Terraform 経由(推奨)
#   PARTICIPANT=alice FLAG_SECRET=xxxx ./setup.sh                          # 手動検証用
#
# Terraform はフラグを事前計算して渡す。FLAG_SECRET を VM に渡すと user-data
# (IMDS 経由で参加者本人が読める)から他人のフラグを偽造できてしまうため。
set -euo pipefail

PARTICIPANT=${PARTICIPANT:?participant name required}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CH_DIR=/opt/handson/ch01
FLAG_DIR=/etc/handson/flags

# flag{<hex>} を人別に生成する。qid と長さ(hex 文字数)を指定。
gen_flag() {
    local qid=$1 len=$2
    local hex
    hex=$(printf '%s' "${PARTICIPANT}:ch01-${qid}" |
        openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-"$len")
    printf 'flag{%s}' "$hex"
}

# 事前計算フラグが渡されていなければ FLAG_SECRET から計算する
if [ -z "${FLAG_Q1:-}" ] || [ -z "${FLAG_Q2:-}" ]; then
    FLAG_SECRET=${FLAG_SECRET:?FLAG_Q1/FLAG_Q2 or FLAG_SECRET required}
    FLAG_Q1=$(gen_flag q1 32)
    FLAG_Q2=$(gen_flag q2 16)
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq build-essential strace ltrace sysstat openssl

mkdir -p "$CH_DIR" "$CH_DIR/lib" "$FLAG_DIR"
chmod 755 /etc/handson
chmod 700 "$FLAG_DIR"

# submit コマンドが参照する参加者情報と採点サーバー URL
echo "$PARTICIPANT" >/etc/handson/participant
chmod 644 /etc/handson/participant
if [ -n "${GRADER_URL:-}" ]; then
    echo "$GRADER_URL" >/etc/handson/grader_url
    chmod 644 /etc/handson/grader_url
fi
install -m 755 "$SCRIPT_DIR/../../tools/submit" /usr/local/bin/submit

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# ---------------------------------------------------------------
# 問題1: oracle — フラグを /dev/null に write(2) するバイナリ。
# strace のデフォルト表示(-s 32)で末尾が切れる長さにするため hex 32 文字。
# strings 対策としてフラグは XOR 0x5A で埋め込む。
# ---------------------------------------------------------------
enc=""
for ((i = 0; i < ${#FLAG_Q1}; i++)); do
    printf -v b '0x%02x,' $(($(printf '%d' "'${FLAG_Q1:$i:1}") ^ 0x5A))
    enc+=$b
done
printf 'static const unsigned char enc[] = {%s};\n' "$enc" >"$BUILD_DIR/enc.h"
cp "$SCRIPT_DIR/src/oracle.c" "$BUILD_DIR/"
gcc -O1 -I"$BUILD_DIR" -o "$CH_DIR/oracle" "$BUILD_DIR/oracle.c"
strip "$CH_DIR/oracle"
chmod 755 "$CH_DIR/oracle"

# ---------------------------------------------------------------
# 問題2: greeter — 共有ライブラリを ld.so の探索パス外に置いて壊す。
# リンク時のみ有効な libgreet.so シンボリックリンクはビルドディレクトリに
# しか作らないので、実行時に libgreet.so.1 の解決に失敗する。
# ---------------------------------------------------------------
gcc -shared -fPIC -Wl,-soname,libgreet.so.1 \
    -o "$CH_DIR/lib/libgreet.so.1" "$SCRIPT_DIR/src/libgreet.c"
ln -sf "$CH_DIR/lib/libgreet.so.1" "$BUILD_DIR/libgreet.so"
gcc -o "$CH_DIR/greeter" "$SCRIPT_DIR/src/greeter.c" -L"$BUILD_DIR" -lgreet
chmod 755 "$CH_DIR/greeter"

printf '%s' "$FLAG_Q2" >"$FLAG_DIR/ch01-q2"
chmod 600 "$FLAG_DIR/ch01-q2"

# ローカル採点用の答えハッシュ(sha256 なので参加者が読んでも逆算不能)
ANSWER_DIR=/etc/handson/answers
mkdir -p "$ANSWER_DIR"
printf '%s' "$FLAG_Q1" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch01-q1.sha256"
printf '%s' "$FLAG_Q2" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch01-q2.sha256"
chmod 755 "$ANSWER_DIR"
chmod 644 "$ANSWER_DIR"/*.sha256

install -m 755 "$SCRIPT_DIR/check.sh" /usr/local/bin/ch01-check
install -m 644 "$SCRIPT_DIR/README.md" "$CH_DIR/README.md"

# ---------------------------------------------------------------
# 修正タスクの自動判定: 30秒ごとに check を回し、合格したら wall で
# 通知・自動提出して自分自身を止める
# ---------------------------------------------------------------
cat >/etc/systemd/system/handson-autocheck.service <<'UNIT'
[Unit]
Description=handson fix-task auto check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ch01-check --auto
UNIT
cat >/etc/systemd/system/handson-autocheck.timer <<'UNIT'
[Unit]
Description=handson fix-task auto check timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now handson-autocheck.timer

# cloud-init 経由(/opt/src 配下)ならソースを消す。oracle.c を読まれると
# Q1 の種明かしになるため、VM に残すのはビルド済みバイナリだけにする。
# ソースは解説タイムに Slack 等で公開する運用(実行中の自分ごと消しても
# bash は開いた fd から読み続けるので安全)
case "$SCRIPT_DIR" in
/opt/src/*) rm -rf /opt/src ;;
esac

echo "ch01 setup done for ${PARTICIPANT}"
