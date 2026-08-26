#!/bin/bash
#
# 第3章 問題2 の合否判定(/usr/local/bin/ch03-check として配置される)
#
# 合格条件(すべて満たすこと):
#   1. perfsync.service が active のまま(業務上必要なサービスなので止めるのは NG)
#   2. perfsync.service が enabled のまま(再起動後も動き続けること)
#   3. 動作中の perfsyncd の nice 値が NICE_MIN 以上(いま効いていること)
#   4. 恒久性の実測: check が service を再起動しても nice 値が維持されること
#      (Nice= の drop-in でも ExecStart に nice を挟む方式でも通る。
#       renice だけの一時しのぎはここで元に戻って落ちる)
set -u

UNIT=perfsync.service
NICE_MIN=10

# --auto: systemd timer からの定期実行モード。合格時だけ通知して自動停止する
AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

if [ "$(id -u)" -ne 0 ]; then
    echo "sudo ch03-check で実行してください" >&2
    exit 1
fi

# 参加者のシェル環境(alias や PATH 差し替え等)に影響されないよう、
# 環境変数をクリアした状態で状態を観測する
probe() {
    env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

ng=()

# 1) 同期デーモンを止めていないか(止めるのは修復ではない)
active=$(probe systemctl is-active "$UNIT" 2>/dev/null || true)
if [ "$active" != "active" ]; then
    ng+=("${UNIT} が動いていません (is-active: ${active})。業務上必要なサービスです。止めずに直しましょう")
fi

# 2) 再起動後も動き続けるか
enabled=$(probe systemctl is-enabled "$UNIT" 2>/dev/null || true)
case "$enabled" in
enabled*) ;;
*)
    ng+=("${UNIT} の自動起動が無効です (is-enabled: ${enabled})。再起動後も動き続ける必要があります")
    ;;
esac

# サービスの main プロセスの nice 値を返す(取れなければ空)
main_nice() {
    local pid
    pid=$(probe systemctl show -p MainPID --value "$UNIT" 2>/dev/null || true)
    if [ "${pid:-0}" -gt 0 ] 2>/dev/null; then
        probe ps -o ni= -p "$pid" 2>/dev/null | tr -d ' '
    fi
}

# 3) いま動いているプロセスで優先度が下がっているか
ni=$(main_nice)
if ! [ "${ni:-0}" -ge "$NICE_MIN" ] 2>/dev/null; then
    ng+=("動作中の perfsyncd の nice 値が ${ni:-不明} です。${NICE_MIN} 以上(いちばん譲るのは 19)に下げましょう。unit の設定を変えたら systemctl restart で反映を")
fi

# 4) 恒久対策になっているか: 実際に再起動して nice 値が維持されるか確かめる
#    (1〜3 がそろったときだけ行う。renice だけの一時しのぎはここで元に戻る)
if [ "${#ng[@]}" -eq 0 ]; then
    # 直前に参加者が restart を繰り返していても start-limit で失敗しないように
    probe systemctl reset-failed "$UNIT" >/dev/null 2>&1
    probe systemctl restart "$UNIT" >/dev/null 2>&1
    sleep 1
    ni=$(main_nice)
    if ! [ "${ni:-0}" -ge "$NICE_MIN" ] 2>/dev/null; then
        ng+=("再起動テストで nice 値が ${ni:-不明} に戻りました。renice は動作中のプロセスにしか効きません。unit の設定(systemctl edit など)で恒久化しましょう")
    elif [ "$AUTO" -eq 0 ]; then
        echo "(恒久性の確認のため ${UNIT} を再起動しました)"
    fi
fi

if [ "${#ng[@]}" -eq 0 ]; then
    flag=$(cat /etc/handson/flags/ch03-q2)
    if [ "$AUTO" -eq 1 ]; then
        submit "$flag" >/dev/null 2>&1 || true
        wall "🎉 第3章 問題2 クリア！(自動判定・提出済み)" 2>/dev/null || true
        systemctl disable --now handson-autocheck.timer >/dev/null 2>&1 || true
        exit 0
    fi
    echo "OK! 同期デーモンは CPU を譲るようになり、集計ジョブは平常に戻りました。フラグ: $flag"
    # 合格したら自動提出(正解すると Slack にお祝いが流れる)
    if command -v submit >/dev/null; then
        submit "$flag"
    fi
else
    # 定期実行時は未達でも黙って次の周期を待つ
    if [ "$AUTO" -eq 1 ]; then
        exit 0
    fi
    echo "NG: まだ修復できていません"
    for msg in "${ng[@]}"; do
        echo "  - $msg"
    done
    exit 1
fi
