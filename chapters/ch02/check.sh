#!/bin/bash
#
# 第2章 問題2 の合否判定(/usr/local/bin/ch02-check として配置される)
#
# 合格条件は README の「恒久的に」の定義と同じ2点:
#   1. いま動いていない — ユニットの状態だけでなく immortal.py のプロセス実在を
#      実測する(ユニットファイルを消しても daemon-reload ではプロセスは死なない)
#   2. OS 再起動後も復活しない — is-enabled が enabled でない。ユニットファイル
#      ごと消した(LoadState=not-found)場合も起動しないので合格
set -u

# --auto: systemd timer からの定期実行モード。合格時だけ通知して自動停止する
AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

if [ "$(id -u)" -ne 0 ]; then
    echo "sudo ch02-check で実行してください" >&2
    exit 1
fi

# 参加者のシェル環境に依存せずに判定するため、クリーンな環境変数で問い合わせる
UNIT=handson-immortal.service
sctl() { env -i /usr/bin/systemctl "$@" 2>/dev/null; }
enabled=$(sctl is-enabled "$UNIT" || true)
active=$(sctl is-active "$UNIT" || true)
load=$(sctl show -p LoadState --value "$UNIT" || true)

permanent=1
case "$enabled" in
enabled | enabled-runtime) permanent=0 ;;
"") [ "$load" = "not-found" ] || permanent=0 ;;
esac

pids=$(pgrep -f '^(/usr/bin/)?python3? /opt/handson/ch02/immortal\.py' | tr '\n' ' ' || true)
stopped=1
[ -z "$pids" ] || stopped=0
case "$active" in
active | activating | reloading) stopped=0 ;;
esac

if [ "$permanent" -eq 1 ] && [ "$stopped" -eq 1 ]; then
    flag=$(cat /etc/handson/flags/ch02-q2)
    if [ "$AUTO" -eq 1 ]; then
        submit "$flag" >/dev/null 2>&1 || true
        wall "🎉 第2章 問題2 クリア！(自動判定・提出済み)" 2>/dev/null || true
        systemctl disable --now handson-autocheck.timer >/dev/null 2>&1 || true
        exit 0
    fi
    echo "OK! handson-immortal は恒久的に無効化されています。フラグ: $flag"
    if command -v submit >/dev/null; then
        submit "$flag"
    fi
else
    # 定期実行時は未達でも黙って次の周期を待つ
    if [ "$AUTO" -eq 1 ]; then
        exit 0
    fi
    echo "NG: handson-immortal はまだ恒久的に無効化されていません"
    if [ "$stopped" -eq 1 ]; then
        echo "  いま動いていない: OK"
    else
        echo "  いま動いていない: NG (is-active=${active:-?}${pids:+, PID $pids})"
    fi
    if [ "$permanent" -eq 1 ]; then
        echo "  OS 再起動後も復活しない: OK"
    else
        echo "  OS 再起動後も復活しない: NG (is-enabled=${enabled:-?}: 起動時に立ち上がる設定のまま)"
    fi
    exit 1
fi
