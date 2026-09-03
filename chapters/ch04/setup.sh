#!/bin/bash
#
# 第4章ハンズオンの環境セットアップ(root で実行、cloud-init から呼ばれる想定)
#
#   PARTICIPANT=alice FLAG_Q1='flag{...}' FLAG_Q2='flag{...}' ./setup.sh   # Terraform 経由(推奨)
#   PARTICIPANT=alice FLAG_SECRET=xxxx ./setup.sh                          # 手動検証用
#
# Terraform はフラグを事前計算して渡す。FLAG_SECRET を VM に渡すと user-data
# (IMDS 経由で参加者本人が読める)から他人のフラグを偽造できてしまうため。
set -euo pipefail

PARTICIPANT=${PARTICIPANT:?participant name required}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CH_DIR=/opt/handson/ch04
FLAG_DIR=/etc/handson/flags

# flag{<hex>} を人別に生成する。qid と長さ(hex 文字数)を指定。
gen_flag() {
    local qid=$1 len=$2
    local hex
    hex=$(printf '%s' "${PARTICIPANT}:ch04-${qid}" |
        openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-"$len")
    printf 'flag{%s}' "$hex"
}

# 事前計算フラグが渡されていなければ FLAG_SECRET から計算する
if [ -z "${FLAG_Q1:-}" ] || [ -z "${FLAG_Q2:-}" ]; then
    FLAG_SECRET=${FLAG_SECRET:?FLAG_Q1/FLAG_Q2 or FLAG_SECRET required}
    FLAG_Q1=$(gen_flag q1 32)
    FLAG_Q2=$(gen_flag q2 32)
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq build-essential gdb sysstat python3 openssl

mkdir -p "$CH_DIR" "$FLAG_DIR"
chmod 755 /etc/handson
chmod 700 "$FLAG_DIR"

# submit コマンドが参照する参加者情報と採点サーバー URL
echo "$PARTICIPANT" >/etc/handson/participant
chmod 644 /etc/handson/participant
if [ -n "${GRADER_ARN:-}" ]; then
    echo "$GRADER_ARN" >/etc/handson/grader_arn
    chmod 644 /etc/handson/grader_arn
fi
install -m 755 "$SCRIPT_DIR/../../tools/submit" /usr/local/bin/submit

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# ---------------------------------------------------------------
# 問題1: ch04-keeper — フラグを mmap した無名メモリ領域に置いて常駐するデーモン。
# フラグはメモリ上にしか無く、実行ファイルには XOR 0x5A で難読化した配列しか残らない。
# 参加者は /proc/<pid>/maps で領域を特定し、コアダンプ等で中身を取り出す。
# ---------------------------------------------------------------
enc=""
for ((i = 0; i < ${#FLAG_Q1}; i++)); do
    printf -v b '0x%02x,' $(($(printf '%d' "'${FLAG_Q1:$i:1}") ^ 0x5A))
    enc+=$b
done
printf 'static const unsigned char enc[] = {%s};\n' "$enc" >"$BUILD_DIR/enc.h"
cp "$SCRIPT_DIR/src/keeper.c" "$BUILD_DIR/"
gcc -O1 -I"$BUILD_DIR" -o "$CH_DIR/ch04-keeper" "$BUILD_DIR/keeper.c"
strip "$CH_DIR/ch04-keeper"
chmod 755 "$CH_DIR/ch04-keeper"

cat >/etc/systemd/system/ch04-keeper.service <<'UNIT'
[Unit]
Description=ch04 flag keeper (holds the flag only in memory)

[Service]
Type=simple
ExecStart=/opt/handson/ch04/ch04-keeper
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

# ---------------------------------------------------------------
# 問題2: ch04-app — 作業に約120MiBのメモリを要するワーカー。ところが unit の
# MemoryMax が 64M に絞られているため、メモリを触っている最中に cgroup の
# OOM killer に殺されつづける。参加者は MemoryMax を十分な値へ恒久修正する。
# ---------------------------------------------------------------
install -m 755 "$SCRIPT_DIR/src/worker.py" "$CH_DIR/worker.py"
mkdir -p /var/lib/ch04-app
chmod 755 /var/lib/ch04-app

cat >/etc/systemd/system/ch04-app.service <<'UNIT'
[Unit]
Description=ch04 memory-hungry worker (needs fixing)

[Service]
Type=simple
ExecStartPre=-/bin/rm -f /var/lib/ch04-app/status
ExecStart=/usr/bin/python3 /opt/handson/ch04/worker.py
Restart=on-failure
RestartSec=15
MemoryMax=64M

[Install]
WantedBy=multi-user.target
UNIT

# ---------------------------------------------------------------
# フラグとローカル採点用ハッシュの配置
# ---------------------------------------------------------------
# Q1 のフラグ平文は VM 上のどこにも置かない(生きたプロセスのメモリから回収させる)。
# Q2(修正課題)のフラグ平文だけを root 専用で置く。
printf '%s' "$FLAG_Q2" >"$FLAG_DIR/ch04-q2"
chmod 600 "$FLAG_DIR/ch04-q2"

# ローカル採点用の答えハッシュ(sha256 なので参加者が読んでも逆算不能)
ANSWER_DIR=/etc/handson/answers
mkdir -p "$ANSWER_DIR"
printf '%s' "$FLAG_Q1" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch04-q1.sha256"
printf '%s' "$FLAG_Q2" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch04-q2.sha256"
chmod 755 "$ANSWER_DIR"
chmod 644 "$ANSWER_DIR"/*.sha256

install -m 755 "$SCRIPT_DIR/check.sh" /usr/local/bin/ch04-check
install -m 644 "$SCRIPT_DIR/README.md" "$CH_DIR/README.md"

# ---------------------------------------------------------------
# サービスの起動
# ---------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now ch04-keeper.service
systemctl enable --now ch04-app.service

# ---------------------------------------------------------------
# 修正タスクの自動判定: 30秒ごとに check を回し、合格したら wall で
# 通知・自動提出して自分自身を止める
# ---------------------------------------------------------------
cat >/etc/systemd/system/handson-autocheck.service <<'UNIT'
[Unit]
Description=handson fix-task auto check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ch04-check --auto
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

# cloud-init 経由(/opt/src 配下)ならソースを消す。keeper.c を読まれると
# Q1 の種明かし(XOR 難読化とメモリ配置)になるため、VM に残すのはビルド済み
# バイナリだけにする。worker.py は実行に必要なので /opt/handson に残す
# (フラグを含まないので問題ない)。解説タイムに src/ を Slack で公開する運用。
case "$SCRIPT_DIR" in
/opt/src/*) rm -rf /opt/src ;;
esac

echo "ch04 setup done for ${PARTICIPANT}"
