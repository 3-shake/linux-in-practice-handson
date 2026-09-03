#!/bin/bash
#
# 第4章 問題2 の合否判定(/usr/local/bin/ch04-check として配置される)
#
# 設定値ではなく実挙動で判定する:
#   1. status を初期化(消せなければ改ざんとみなす)してクリーン再起動
#   2. worker が OK を書くまで待つ
#   3. この起動でユニットの cgroup が実際に必要量のメモリを使ったか(memory.peak)
#   4. OK のあとも同じプロセスが安定稼働しているか(直後の OOM 死・偽装を弾く)
#
set -u

# --auto: systemd timer からの定期実行モード。合格時だけ通知して自動停止する
AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

# 判定ポーリング回数(2秒間隔)。E2E がテスト時間短縮のために上書きする
TRIES=${CH04_CHECK_TRIES:-30}

if [ "$(id -u)" -ne 0 ]; then
    echo "sudo ch04-check で実行してください" >&2
    exit 1
fi

STATUS=/var/lib/ch04-app/status
# worker が作業に必要とする約 120MiB に対し余裕を見た下限。これ未満しか
# 使わずに OK が現れた場合はワークロード改変や status 偽造とみなす
PEAK_MIN=$((110 * 1024 * 1024))

ng_exit() {
    # 定期実行時は未達でも黙って次の周期を待つ
    if [ "$AUTO" -eq 1 ]; then
        exit 0
    fi
    echo "NG: $1"
    echo "--- systemctl status ---"
    systemctl --no-pager --lines=5 status ch04-app 2>&1 || true
    echo "--- 直近の OOM(dmesg)---"
    dmesg 2>/dev/null | grep -i 'out of memory' | tail -n 3 || true
    exit 1
}

# その場しのぎ(手動で1回だけ起動して通す等)を弾くため、設定を読み直して
# サービスをクリーンに再起動し、恒久修復されているかを確かめる。
# 恒久的に MemoryMax を直していれば再起動後も OOM で殺されず OK を書ける。
systemctl daemon-reload >/dev/null 2>&1 || true
rm -f "$STATUS" 2>/dev/null
if [ -e "$STATUS" ]; then
    ng_exit "判定用の status ファイルを初期化できません(書き込み保護などを検出)。"
fi
systemctl restart ch04-app >/dev/null 2>&1 || true

# worker が 120MiB を触り終えて status に OK を書くまで待つ(MemoryMax が
# 足りないと途中で OOM kill され、いつまでも OK にならない)。
ok=0
for _ in $(seq 1 "$TRIES"); do
    if systemctl is-active --quiet ch04-app &&
        [ "$(cat "$STATUS" 2>/dev/null)" = "OK" ]; then
        ok=1
        break
    fi
    sleep 2
done
[ "$ok" -eq 1 ] || ng_exit "ch04-app はまだ正常稼働していません。"

# この起動でユニットの cgroup が実際に必要量のメモリを使った形跡があるか。
# status の文字列だけを偽造しても、実挙動(カーネルの実測カウンタ)は残らない
cg=$(systemctl show -p ControlGroup --value ch04-app 2>/dev/null)
peak=$(cat "/sys/fs/cgroup${cg}/memory.peak" 2>/dev/null || echo 0)
if [ "${peak:-0}" -lt "$PEAK_MIN" ]; then
    ng_exit "ch04-app が必要量のメモリを確保して稼働した形跡がありません(判定はワーカーの実挙動を見ています)。"
fi

# OK を書いたあとも同じプロセスが安定稼働しているか(書いた直後に OOM で
# 死んでいる・別プロセスが OK を書いている、を弾く)
mainpid=$(systemctl show -p MainPID --value ch04-app 2>/dev/null)
sleep 5
if ! systemctl is-active --quiet ch04-app ||
    [ "$(cat "$STATUS" 2>/dev/null)" != "OK" ] ||
    [ "$(systemctl show -p MainPID --value ch04-app 2>/dev/null)" != "$mainpid" ]; then
    ng_exit "ch04-app が安定稼働していません(OK の直後に落ちています)。"
fi

flag=$(cat /etc/handson/flags/ch04-q2)
if [ "$AUTO" -eq 1 ]; then
    submit "$flag" >/dev/null 2>&1 || true
    wall "🎉 第4章 問題2 クリア！(自動判定・提出済み)" 2>/dev/null || true
    systemctl disable --now handson-autocheck.timer >/dev/null 2>&1 || true
    exit 0
fi
echo "OK! ch04-app は OOM に殺されず正常稼働しています。フラグ: $flag"
# 合格したら自動提出(正解すると Slack にお祝いが流れる)
if command -v submit >/dev/null; then
    submit "$flag"
fi
