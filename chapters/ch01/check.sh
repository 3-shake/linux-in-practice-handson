#!/bin/bash
#
# 第1章 問題2 の合否判定(/usr/local/bin/ch01-check として配置される)
#
set -u

# --auto: systemd timer からの定期実行モード。合格時だけ通知して自動停止する
AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

if [ "$(id -u)" -ne 0 ]; then
    echo "sudo ch01-check で実行してください" >&2
    exit 1
fi

# LD_LIBRARY_PATH などによる一時しのぎを無効化するため、環境変数を
# クリアした状態で実行する(恒久対策=ld.so 側の設定修正を要求する)
out=$(env -i /opt/handson/ch01/greeter 2>&1)
status=$?

if [ "$status" -eq 0 ] && [ "$out" = "Hello from libgreet!" ]; then
    flag=$(cat /etc/handson/flags/ch01-q2)
    if [ "$AUTO" -eq 1 ]; then
        submit "$flag" >/dev/null 2>&1 || true
        wall "🎉 第1章 問題2 クリア！(自動判定・提出済み)" 2>/dev/null || true
        systemctl disable --now handson-autocheck.timer >/dev/null 2>&1 || true
        exit 0
    fi
    echo "OK! greeter は正常に動作しています。フラグ: $flag"
    # 合格したら自動提出(正解すると Slack にお祝いが流れる)
    if command -v submit >/dev/null; then
        submit "$flag"
    fi
else
    # 定期実行時は未達でも黙って次の周期を待つ
    if [ "$AUTO" -eq 1 ]; then
        exit 0
    fi
    echo "NG: greeter はまだ正しく動いていません (exit=${status})"
    echo "--- 出力 ---"
    echo "$out"
    exit 1
fi
