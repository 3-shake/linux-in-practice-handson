#!/bin/bash
#
# 第3章ハンズオンの環境セットアップ(root で実行、cloud-init から呼ばれる想定)
#
#   PARTICIPANT=alice FLAG_Q1='flag{...}' FLAG_Q2='flag{...}' ./setup.sh   # Terraform 経由(推奨)
#   PARTICIPANT=alice FLAG_SECRET=xxxx ./setup.sh                          # 手動検証用
#
# Terraform はフラグを事前計算して渡す。FLAG_SECRET を VM に渡すと user-data
# (IMDS 経由で参加者本人が読める)から他人のフラグを偽造できてしまうため。
set -euo pipefail

PARTICIPANT=${PARTICIPANT:?participant name required}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CH_DIR=/opt/handson/ch03
LIB_DIR=/usr/local/lib/ch03
FLAG_DIR=/etc/handson/flags

# flag{<hex>} を人別に生成する。qid と長さ(hex 文字数)を指定。
gen_flag() {
    local qid=$1 len=$2
    local hex
    hex=$(printf '%s' "${PARTICIPANT}:ch03-${qid}" |
        openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-"$len")
    printf 'flag{%s}' "$hex"
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq build-essential strace sysstat openssl

# 事前計算フラグが渡されていなければ FLAG_SECRET から計算する
# (openssl のインストール後に行うこと。$(...) は errexit を継承しないため、
#  openssl が無いと flag{} が黙って出来上がってしまう)
if [ -z "${FLAG_Q1:-}" ] || [ -z "${FLAG_Q2:-}" ]; then
    FLAG_SECRET=${FLAG_SECRET:?FLAG_Q1/FLAG_Q2 or FLAG_SECRET required}
    FLAG_Q1=$(gen_flag q1 32)
    FLAG_Q2=$(gen_flag q2 32)
fi
if [ "${#FLAG_Q1}" -lt 10 ] || [ "${#FLAG_Q2}" -lt 10 ]; then
    echo "flag generation failed" >&2
    exit 1
fi

mkdir -p "$CH_DIR" "$LIB_DIR" "$FLAG_DIR"
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
# 問題1: oracle — 「論理CPU0 に縛られ、nice 値がいちばん低い側」の
# ときだけフラグを表示する預言者バイナリ(taskset と nice の実地演習)。
# strings 対策としてフラグは XOR 0x37 で埋め込む。
# ---------------------------------------------------------------
enc=""
for ((i = 0; i < ${#FLAG_Q1}; i++)); do
    printf -v b '0x%02x,' $(($(printf '%d' "'${FLAG_Q1:$i:1}") ^ 0x37))
    enc+=$b
done
printf 'static const unsigned char enc[] = {%s};\n' "$enc" >"$BUILD_DIR/enc.h"
cp "$SCRIPT_DIR/src/oracle.c" "$BUILD_DIR/"
gcc -O1 -I"$BUILD_DIR" -o "$CH_DIR/oracle" "$BUILD_DIR/oracle.c"
strip "$CH_DIR/oracle"
chmod 755 "$CH_DIR/oracle"

# 準備運動用: 本章リスト03-01 の負荷プログラム
install -m 755 "$SCRIPT_DIR/src/load.py" "$CH_DIR/load.py"

# ---------------------------------------------------------------
# 問題2: perfsyncd — 「業務上必要」という建て付けの同期デーモン。
# taskset -c 1 + nice 0 のまま、デューティサイクル(busy 60ms/sleep 40ms)
# で論理CPU1 を約6割使い、同じ CPU1 固定の集計ジョブ report を
# 約1.4倍遅くする。恒久修復は止めることではなく、unit の設定
# (Nice= の drop-in や ExecStart への nice 挿入)で優先度を
# 10 以上(想定 19)に下げて共存させること。
# ---------------------------------------------------------------
gcc -O0 -o "$LIB_DIR/perfsyncd" "$SCRIPT_DIR/src/perfsyncd.c"
strip "$LIB_DIR/perfsyncd"
chmod 755 "$LIB_DIR/perfsyncd"

cat >/etc/systemd/system/perfsync.service <<'UNIT'
[Unit]
Description=Performance data sync daemon
# 参加者が kill や restart を連打しても start-limit で死なないようにする
# (check の再起動テストと「必ず蘇る」という出題の前提を守る)
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/taskset -c 1 /usr/local/lib/ch03/perfsyncd
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# 被害者: 日次集計ジョブ(nice 0、論理CPU1 固定)。修復の前後で所要時間を比べる
install -m 755 "$SCRIPT_DIR/src/report.py" "$CH_DIR/report"

printf '%s' "$FLAG_Q2" >"$FLAG_DIR/ch03-q2"
chmod 600 "$FLAG_DIR/ch03-q2"

# ローカル採点用の答えハッシュ(sha256 なので参加者が読んでも逆算不能)
ANSWER_DIR=/etc/handson/answers
mkdir -p "$ANSWER_DIR"
printf '%s' "$FLAG_Q1" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch03-q1.sha256"
printf '%s' "$FLAG_Q2" | sha256sum | cut -d' ' -f1 >"$ANSWER_DIR/ch03-q2.sha256"
chmod 755 "$ANSWER_DIR"
chmod 644 "$ANSWER_DIR"/*.sha256

install -m 755 "$SCRIPT_DIR/check.sh" /usr/local/bin/ch03-check
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
ExecStart=/usr/local/bin/ch03-check --auto
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
systemctl enable --now perfsync.service
systemctl enable --now handson-autocheck.timer

# cloud-init 経由(/opt/src 配下)ならソースを消す。oracle.c を読まれると
# Q1 の種明かしになるため、VM に残すのはビルド済みバイナリだけにする。
# ソースは解説タイムに Slack 等で公開する運用(実行中の自分ごと消しても
# bash は開いた fd から読み続けるので安全)
case "$SCRIPT_DIR" in
/opt/src/*) rm -rf /opt/src ;;
esac

echo "ch03 setup done for ${PARTICIPANT}"
