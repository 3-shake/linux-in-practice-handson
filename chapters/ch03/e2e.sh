#!/bin/bash
#
# 第3章 問題2 の E2E テスト。tools/e2e ch03 [instance-id] で VM 上で root
# として実行される。前提: 現行 setup.sh で仕込まれた VM(perfsync.service に
# StartLimitIntervalSec=0 が入っていること)。
#
# リポジトリの最新 check.sh を配置し、不合格系 → 合格系 → 後始末の順に
# 判定の挙動を検証する。終了時は未修復状態に戻し、autocheck timer を再開する。
set -u
. "${E2E_SRC:?}/tools/e2e-lib.sh"

U=perfsync.service
D=/etc/systemd/system/perfsync.service.d

pni() { ps -o ni= -p "$(systemctl show -p MainPID --value $U)" 2>/dev/null | tr -d ' '; }

# リポジトリの最新 check.sh で試験する
install -m 755 "$E2E_SRC/chapters/ch03/check.sh" /usr/local/bin/ch03-check
echo "リポジトリの check.sh を配置した"

# 合格ケースの自動 submit による通知スパムを抑止(提出済みマーカーを先に作る)
flag=$(cat /etc/handson/flags/ch03-q2)
touch "/var/tmp/.handson-submitted-$(printf '%s' "$flag" | sha256sum | cut -c1-16)"

# 初期化: 過去の修復と failed 状態を撤去して未修復に戻す
rm -rf "$D"
systemctl daemon-reload
systemctl reset-failed $U 2>/dev/null || true
systemctl restart $U
sleep 1

case_begin "未修復(nice 0) → NG"
expect ng ch03-check
expect_out "nice 値が 0"

case_begin "renice のみ → 再起動テストで NG、nice は 0 に戻る"
renice -n 19 -p "$(systemctl show -p MainPID --value $U)" >/dev/null
expect ng ch03-check
expect_out "再起動テストで"
if [ "$(pni)" = "0" ]; then pass "nice が 0 に戻った"; else fail "nice=$(pni)"; fi

case_begin "drop-in のみ(restart 忘れ) → NG"
mkdir -p "$D"
printf '[Service]\nNice=19\n' >"$D/override.conf"
systemctl daemon-reload
expect ng ch03-check
expect_out "systemctl restart"

case_begin "Nice=19 drop-in + restart(想定解) → OK"
systemctl restart $U
sleep 1
expect ok ch03-check
expect_out "OK!"

case_begin "restart 連打の直後でも check が壊れない(start-limit 回帰)"
for _ in 1 2 3 4 5; do systemctl restart $U; done
sleep 1
expect ok ch03-check
expect_out "OK!"

case_begin "ExecStart に nice を挟む方式 → OK"
printf '[Service]\nExecStart=\nExecStart=/usr/bin/nice -n 19 /usr/bin/taskset -c 1 /usr/local/lib/ch03/perfsyncd\n' >"$D/override.conf"
systemctl daemon-reload
systemctl restart $U
sleep 1
expect ok ch03-check
expect_out "OK!"

case_begin "stop したまま → NG(止めるのは修復でない)"
systemctl stop $U
expect ng ch03-check
expect_out "止めずに"
systemctl start $U

case_begin "disable → NG(再起動後も動き続ける必要がある)"
systemctl disable $U >/dev/null 2>&1
expect ng ch03-check
expect_out "自動起動が無効"
systemctl enable $U >/dev/null 2>&1

# 後始末: 未修復状態に戻し、自動判定タイマーを再開する
rm -rf "$D"
systemctl daemon-reload
systemctl restart $U
systemctl enable --now handson-autocheck.timer >/dev/null 2>&1 || true
echo
echo "(後始末: 未修復状態に戻し、autocheck timer を再開した)"

e2e_end
