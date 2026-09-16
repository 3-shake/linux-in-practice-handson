#!/bin/bash
#
# 第2章 問題2 の E2E テスト。tools/e2e ch02 [instance-id] で VM 上で root
# として実行される。リポジトリの最新 check.sh を配置し、不合格系 → 合格系
# (別解含む)→ 後始末の順に判定の挙動を検証する。終了時は未修復状態に戻し、
# autocheck timer を再開する。
set -u
. "${E2E_SRC:?}/tools/e2e-lib.sh"

U=handson-immortal.service
UNIT_FILE=/etc/systemd/system/$U
D=/etc/systemd/system/$U.d
BAK=/opt/e2e/immortal.service.bak

install -m 755 "$E2E_SRC/chapters/ch02/check.sh" /usr/local/bin/ch02-check
echo "リポジトリの check.sh を配置した"

# 合格ケースの自動 submit による通知スパムを抑止(提出済みマーカーを先に作る)
flag=$(cat /etc/handson/flags/ch02-q2)
touch "/var/tmp/.handson-submitted-$(printf '%s' "$flag" | sha256sum | cut -c1-16)"

# ユニットファイルの原本を確保する。参加者(や前回の E2E)が消していたら
# setup.sh のヒアドキュメントから取り出す
if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then
    cp "$UNIT_FILE" "$BAK"
elif [ ! -f "$BAK" ]; then
    sed -n "\#^cat >$UNIT_FILE <<'UNIT'#,/^UNIT\$/p" "$E2E_SRC/chapters/ch02/setup.sh" |
        sed '1d;$d' >"$BAK"
fi
grep -q '^ExecStart=' "$BAK" || { echo "ユニット原本を復元できない" >&2; exit 1; }

# 未修復状態(enabled かつ動いている)に戻す
restore() {
    rm -rf "$D"
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    systemctl unmask $U >/dev/null 2>&1 || true
    install -m 644 "$BAK" "$UNIT_FILE"
    systemctl daemon-reload
    systemctl reset-failed $U 2>/dev/null || true
    systemctl enable --now $U >/dev/null 2>&1
    sleep 1
}
mainpid() { systemctl show -p MainPID --value $U; }
restore

case_begin "未修復 → NG(両方 NG)"
expect ng ch02-check
expect_out "いま動いていない: NG"
expect_out "OS 再起動後も復活しない: NG"

case_begin "kill -9 だけ → NG(復活する。復活前後どちらでも NG)"
kill -9 "$(mainpid)"
expect ng ch02-check
expect_out "OS 再起動後も復活しない: NG"
sleep 3
expect ng ch02-check
expect_out "いま動いていない: NG"

case_begin "systemctl stop だけ → NG(止まっているが再起動で復活)"
systemctl stop $U
expect ng ch02-check
expect_out "いま動いていない: OK"
expect_out "OS 再起動後も復活しない: NG"
systemctl start $U
sleep 1

case_begin "Restart=no の drop-in + kill -9 → NG(enabled のまま)"
mkdir -p "$D"
printf '[Service]\nRestart=no\n' >"$D/override.conf"
systemctl daemon-reload
kill -9 "$(mainpid)"
sleep 2
expect ng ch02-check
expect_out "いま動いていない: OK"
expect_out "OS 再起動後も復活しない: NG"
restore

case_begin "disable --now(想定解) → OK"
systemctl disable --now $U >/dev/null 2>&1
expect ok ch02-check
expect_out "OK!"
restore

case_begin "stop → disable と別々に打つ → OK"
systemctl stop $U
systemctl disable $U >/dev/null 2>&1
expect ok ch02-check
expect_out "OK!"
restore

case_begin "mask --now → /etc にユニット実体があるので mask 自体が失敗し NG のまま"
expect ng systemctl mask --now $U
expect ng ch02-check
restore

case_begin "ユニットファイルを消して daemon-reload(プロセスは生きている) → NG"
rm -f "$UNIT_FILE"
systemctl daemon-reload
expect ng ch02-check
expect_out "いま動いていない: NG"

case_begin "続けて kill -9 → OK(not-found なので復活しない)"
pkill -9 -f 'immortal\.py'
sleep 2
expect ok ch02-check
expect_out "OK!"
restore

# 後始末: 未修復状態のまま、自動判定タイマーを再開する
systemctl enable --now handson-autocheck.timer >/dev/null 2>&1 || true
echo
echo "(後始末: 未修復状態に戻し、autocheck timer を再開した)"

e2e_end
