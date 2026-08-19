#!/bin/bash
#
# 第2章ハンズオンの環境セットアップ(root で実行、cloud-init から呼ばれる想定)
#
#   PARTICIPANT=alice FLAG_Q1='flag{...}' FLAG_Q2='flag{...}' ./setup.sh   # Terraform 経由(推奨)
#   PARTICIPANT=alice FLAG_SECRET=xxxx ./setup.sh                          # 手動検証用
#
# Terraform はフラグを事前計算して渡す。FLAG_SECRET を VM に渡すと user-data
# (IMDS 経由で参加者本人が読める)から他人のフラグを偽造できてしまうため。
set -euo pipefail

PARTICIPANT=${PARTICIPANT:?participant name required}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CH_DIR=/opt/handson/ch02
FLAG_DIR=/etc/handson/flags

# flag{<hex>} を人別に生成する。qid と長さ(hex 文字数)を指定。
gen_flag() {
    local qid=$1 len=$2
    local hex
    hex=$(printf '%s' "${PARTICIPANT}:ch02-${qid}" |
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
apt-get install -yq build-essential strace ltrace psmisc openssl

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
# 問題1: oracled — フラグを /dev/null に write(2) する常駐デーモン。
# systemd サービスとして起動するので PPID=1 / TTY=? / SID=PID になり、
# 2章「デーモン」の sshd と同じ見た目になる。数秒ごとに write するので
# 動作中プロセスを strace -p すれば観測できる。strace のデフォルト表示
# (-s 32)で末尾が切れる長さにするため hex 32 文字。
# strings 対策としてフラグは XOR 0x5A で埋め込む(平文は残さない)。
# 対話端末から実行すると isatty で弾く(デーモンは端末を持たないので)。
# ---------------------------------------------------------------
enc=""
for ((i = 0; i < ${#FLAG_Q1}; i++)); do
    printf -v b '0x%02x,' $(($(printf '%d' "'${FLAG_Q1:$i:1}") ^ 0x5A))
    enc+=$b
done
printf 'static const unsigned char enc[] = {%s};\n' "$enc" >"$BUILD_DIR/enc.h"
cp "$SCRIPT_DIR/src/oracled.c" "$BUILD_DIR/"
gcc -O1 -I"$BUILD_DIR" -o "$CH_DIR/oracled" "$BUILD_DIR/oracled.c"
strip "$CH_DIR/oracled"
chmod 755 "$CH_DIR/oracled"

cat >/etc/systemd/system/handson-ch02-oracled.service <<'UNIT'
[Unit]
Description=ch02 q1 oracle daemon
After=network.target

[Service]
ExecStart=/opt/handson/ch02/oracled
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

# ---------------------------------------------------------------
# 問題2: handson-immortal — SIGINT/SIGTERM を無視する「倒せない」サービス。
# kill(=SIGTERM)は無視され、kill -9(SIGKILL)で殺しても Restart=always
# で復活する。恒久修復には systemctl disable --now(または mask)が要る。
# systemctl stop 自体が固まらないよう KillSignal=SIGKILL にしておく。
# ---------------------------------------------------------------
install -m 755 "$SCRIPT_DIR/src/immortal.py" "$CH_DIR/immortal.py"
cat >/etc/systemd/system/handson-immortal.service <<'UNIT'
[Unit]
Description=handson immortal (ch02 q2)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/handson/ch02/immortal.py
Restart=always
RestartSec=1
KillSignal=SIGKILL
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now handson-ch02-oracled.service
systemctl enable --now handson-immortal.service

# 修復課題のフラグ平文(q2 のみ。q1 は平文を VM に置かない)
printf '%s' "$FLAG_Q2" >"$FLAG_DIR/ch02-q2"
chmod 600 "$FLAG_DIR/ch02-q2"

# ローカル採点用の答えハッシュ(sha256 なので参加者が読んでも逆算不能)
ANSWER_DIR=/etc/handson/answers
mkdir -p "$ANSWER_DIR"
printf '%s' "$FLAG_Q1" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch02-q1.sha256"
printf '%s' "$FLAG_Q2" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch02-q2.sha256"
chmod 755 "$ANSWER_DIR"
chmod 644 "$ANSWER_DIR"/*.sha256

install -m 755 "$SCRIPT_DIR/check.sh" /usr/local/bin/ch02-check
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
ExecStart=/usr/local/bin/ch02-check --auto
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

# cloud-init 経由(/opt/src 配下)ならソースを消す。oracled.c を読まれると
# Q1 の種明かしになるため、VM に残すのはビルド済みバイナリだけにする。
case "$SCRIPT_DIR" in
/opt/src/*) rm -rf /opt/src ;;
esac

echo "ch02 setup done for ${PARTICIPANT}"
