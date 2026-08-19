#!/bin/bash
#
# 第2章 問題2 の合否判定(/usr/local/bin/ch02-check として配置される)
#
set -u

# --auto: systemd timer からの定期実行モード。合格時だけ通知して自動停止する
AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

if [ "$(id -u)" -ne 0 ]; then
    echo "sudo ch02-check で実行してください" >&2
    exit 1
fi

# 参加者のシェル環境に依存せずに判定するため、クリーンな環境変数で問い合わせる。
# 恒久修復(disable / mask)を要求する。kill / kill -9 だけの一時しのぎは
# サービスが enabled のまま(Restart=always で復活)なので弾かれる。
UNIT=handson-immortal.service
enabled=$(env -i /usr/bin/systemctl is-enabled "$UNIT" 2>/dev/null || true)
active=$(env -i /usr/bin/systemctl is-active "$UNIT" 2>/dev/null || true)

# 恒久停止か: enabled(自動起動する)状態でなく、かつ空でもない
permanent=1
case "$enabled" in
enabled | enabled-runtime | "") permanent=0 ;;
esac

# 今この瞬間に動いていないか
stopped=1
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
    echo "  is-enabled=${enabled:-?} / is-active=${active:-?}"
    echo "  (自動起動を止め[disable または mask]、かつ停止する必要があります)"
    exit 1
fi
