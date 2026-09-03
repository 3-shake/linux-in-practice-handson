#!/bin/bash
#
# 第4章の E2E テスト。tools/e2e ch04 [instance-id] で VM 上で root として実行される。
# 前提: 現行 setup.sh で仕込まれた VM(ch04-keeper / ch04-app が配置済みであること)。
#
# 問題1(CTF)は想定解(gcore)と別解(/proc/<pid>/mem 直読み、静的解析)でフラグを
# 回収できることを検証し、問題2(修正)はリポジトリの最新 check.sh を配置して
# 不合格系 → 合格系 → チート系の順に判定の挙動を検証する。
# 終了時は未修復状態に戻し、autocheck timer を再開する。
set -u
. "${E2E_SRC:?}/tools/e2e-lib.sh"

U=ch04-app.service
UNIT_FILE=/etc/systemd/system/ch04-app.service
D=/etc/systemd/system/ch04-app.service.d
STATUS=/var/lib/ch04-app/status
KEEPER=/opt/handson/ch04/ch04-keeper

# setup.sh が置くのと同一の未修復 unit(MemoryMax=64M)を書き戻す
# (別解に unit ファイル直編集があるため、drop-in の削除だけでは初期化にならない)
write_broken_unit() {
    cat >"$UNIT_FILE" <<'UNIT'
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
}

# 修復の痕跡(drop-in、set-property の永続/一時 drop-in、unit 直編集)を全て撤去する
reset_unfixed() {
    write_broken_unit
    rm -rf "$D" \
        /etc/systemd/system.control/ch04-app.service.d \
        /run/systemd/system.control/ch04-app.service.d
    rm -f "$STATUS"
    systemctl daemon-reload
    systemctl reset-failed $U 2>/dev/null || true
}

# リポジトリの最新 check.sh で試験する
install -m 755 "$E2E_SRC/chapters/ch04/check.sh" /usr/local/bin/ch04-check
echo "リポジトリの check.sh を配置した"

# NG 判定の待ち時間を短縮する(worker は数秒で OK を書くので 10 回×2 秒で十分)
export CH04_CHECK_TRIES=10

# 合格ケースの自動 submit による通知スパムを抑止(提出済みマーカーを先に作る)
flag=$(cat /etc/handson/flags/ch04-q2)
touch "/var/tmp/.handson-submitted-$(printf '%s' "$flag" | sha256sum | cut -c1-16)"

# 試験中に自動判定が横から restart しないよう timer を止める(後始末で再開)
systemctl disable --now handson-autocheck.timer >/dev/null 2>&1 || true
systemctl stop handson-autocheck.service >/dev/null 2>&1 || true

# 初期化: 過去の修復と failed 状態を撤去して未修復に戻す
reset_unfixed
systemctl restart $U

# ---------------------------------------------------------------
# 問題1(CTF): 生きているプロセスのメモリ
# ---------------------------------------------------------------
q1hash=$(cat /etc/handson/answers/ch04-q1.sha256)
q1_flag_ok() {
    [ -n "$1" ] && [ "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)" = "$q1hash" ]
}

case_begin "問題1: keeper が稼働し flag_vault 無名領域を持つ(VSZ 大・RSS 小)"
pid=$(systemctl show -p MainPID --value ch04-keeper)
if [ "${pid:-0}" -gt 0 ] 2>/dev/null; then
    pass "ch04-keeper 稼働中 (pid=$pid)"
else
    fail "ch04-keeper が動いていない (MainPID=$pid)"
fi
expect ok grep -m1 flag_vault "/proc/$pid/maps"
vsz=$(ps -o vsz= -p "$pid" 2>/dev/null | tr -d ' ')
rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
# mmap した 64MiB で VSZ は 64MiB 超、触ったのは先頭ページだけなので RSS は僅か
# (デマンドページングがヒントどおり観察できること)
if [ "${vsz:-0}" -gt 65536 ]; then
    pass "VSZ=${vsz}KiB > 64MiB"
else
    fail "VSZ=${vsz:-?}KiB が 64MiB を超えていない"
fi
if [ "${rss:-999999}" -lt 16384 ]; then
    pass "RSS=${rss}KiB は僅か(< 16MiB)"
else
    fail "RSS=${rss:-?}KiB が大きすぎる(デマンドページングの気配が見えない)"
fi

case_begin "問題1: 実行ファイルの strings に平文フラグは無い(XOR 難読化)"
expect ng bash -c "strings $KEEPER | grep -E 'flag\{'"

case_begin "問題1: 想定解(gcore でコアダンプ → strings)でフラグ回収できる"
rm -f /tmp/e2e-keeper.*
expect ok gcore -o /tmp/e2e-keeper "$pid"
f1=$(strings "/tmp/e2e-keeper.$pid" 2>/dev/null | grep -oE 'flag\{[0-9a-f]+\}' | head -1)
if q1_flag_ok "$f1"; then
    pass "回収フラグが答えハッシュと一致"
else
    fail "回収失敗または不一致: '$f1'"
fi
rm -f /tmp/e2e-keeper.*

case_begin "問題1: 別解(/proc/<pid>/mem 直読み)でも回収できる"
start=$(grep -m1 flag_vault "/proc/$pid/maps" | cut -d- -f1)
if [ -n "$start" ]; then
    f2=$(dd if="/proc/$pid/mem" bs=1 skip=$((16#$start)) count=4096 2>/dev/null |
        strings | grep -oE 'flag\{[0-9a-f]+\}' | head -1)
    if q1_flag_ok "$f2"; then
        pass "回収フラグが答えハッシュと一致"
    else
        fail "回収失敗または不一致: '$f2'"
    fi
else
    fail "flag_vault 領域が /proc/$pid/maps に見つからない"
fi

case_begin "問題1: 別解(静的解析: .rodata を XOR 0x5A で復号)でも回収できる"
# 既知の割り切り: 逆アセンブルすれば XOR キーごと読める。それも正解扱い
objcopy -O binary --only-section=.rodata "$KEEPER" /tmp/e2e-rodata.bin 2>/dev/null
f3=$(python3 -c "
import re
x = bytes(b ^ 0x5A for b in open('/tmp/e2e-rodata.bin','rb').read())
m = re.search(rb'flag\{[0-9a-f]+\}', x)
print(m.group().decode() if m else '')" 2>/dev/null)
if q1_flag_ok "$f3"; then
    pass "回収フラグが答えハッシュと一致"
else
    fail "回収失敗または不一致: '$f3'"
fi
rm -f /tmp/e2e-rodata.bin

# ---------------------------------------------------------------
# 問題2(修正): 不合格系
# ---------------------------------------------------------------
case_begin "未修復(MemoryMax=64M) → NG、失敗原因は cgroup OOM"
expect ng ch04-check
expect_out "NG:"
if journalctl -u $U --since=-3min 2>/dev/null | grep -qi oom; then
    pass "直近ログに OOM kill の痕跡"
else
    fail "直近ログに OOM の痕跡が無い(壊れ方が想定と違う)"
fi

case_begin "MemoryMax=100M に増やしただけでは不足(必要量 ~120MiB) → NG"
mkdir -p "$D"
printf '[Service]\nMemoryMax=100M\n' >"$D/override.conf"
systemctl daemon-reload
expect ng ch04-check
expect_out "NG:"

# ---------------------------------------------------------------
# 問題2(修正): 合格系
# ---------------------------------------------------------------
case_begin "想定解: drop-in で MemoryMax=256M + restart → OK、フラグが出る"
printf '[Service]\nMemoryMax=256M\n' >"$D/override.conf"
systemctl daemon-reload
systemctl restart $U
expect ok ch04-check
expect_out "OK!"
expect_out "$flag"
expect_out "提出済み" # マーカーにより自動 submit がスパムにならないこと

case_begin "別解: unit ファイル直編集(MemoryMax=256M)+ daemon-reload → OK"
reset_unfixed
sed -i 's/MemoryMax=64M/MemoryMax=256M/' "$UNIT_FILE"
systemctl daemon-reload
systemctl restart $U
expect ok ch04-check
expect_out "OK!"

case_begin "別解: systemctl set-property(永続 drop-in)→ OK"
reset_unfixed
systemctl set-property $U MemoryMax=256M
expect ok ch04-check
expect_out "OK!"

case_begin "set-property --runtime → OK(既知の割り切り: 一時 drop-in でも合格)"
reset_unfixed
systemctl set-property --runtime $U MemoryMax=256M
expect ok ch04-check
expect_out "OK!"
# 本当に /run 側の一時 drop-in だけで通っている(= 割り切りの検証になっている)こと
if [ -e /run/systemd/system.control/ch04-app.service.d/50-MemoryMax.conf ] &&
    [ ! -e /etc/systemd/system.control/ch04-app.service.d/50-MemoryMax.conf ]; then
    pass "drop-in は /run のみ(再起動で消える一時修復)"
else
    fail "一時 drop-in の配置が想定と違う"
fi

case_begin "別解: MemoryMax=infinity(制限撤廃)→ OK"
reset_unfixed
mkdir -p "$D"
printf '[Service]\nMemoryMax=infinity\n' >"$D/override.conf"
systemctl daemon-reload
expect ok ch04-check
expect_out "OK!"

case_begin "別解: 専用 slice でメモリ枠を与える(unit 自身の上限は撤去)→ OK"
# cgroup パスが system.slice 以外になるため、check が ControlGroup を
# 動的に辿れていることの検証も兼ねる
reset_unfixed
printf '[Slice]\nMemoryMax=256M\n' >/etc/systemd/system/ch04.slice
sed -i '/^MemoryMax=64M/d; /^\[Service\]/a Slice=ch04.slice' "$UNIT_FILE"
systemctl daemon-reload
systemctl restart $U
expect ok ch04-check
expect_out "OK!"
rm -f /etc/systemd/system/ch04.slice

# ---------------------------------------------------------------
# 問題2(修正): チート系
# ---------------------------------------------------------------
case_begin "チート: status を手書き偽造 → クリーン再起動判定で NG"
reset_unfixed
systemctl stop $U 2>/dev/null
mkdir -p /var/lib/ch04-app
echo OK >"$STATUS"
expect ng ch04-check
expect_out "NG:"
if [ "$(cat "$STATUS" 2>/dev/null)" = "OK" ]; then
    fail "偽造 status が判定後も残っている"
else
    pass "偽造 status は再起動判定で無効化された"
fi

case_begin "チート: worker.py の要求量を 1MiB に改ざん → 実挙動計測で NG"
reset_unfixed
cp -p /opt/handson/ch04/worker.py /tmp/e2e-worker.py.bak
sed -i 's/^REQUIRED = .*/REQUIRED = 1 * 1024 * 1024/' /opt/handson/ch04/worker.py
# 64M 上限のままでも 1MiB なら OK を書けてしまう状態(旧 check はこれを通した)
expect ng ch04-check
expect_out "NG:"
cp -p /tmp/e2e-worker.py.bak /opt/handson/ch04/worker.py
rm -f /tmp/e2e-worker.py.bak

case_begin "チート: ExecStart をメモリを触らないスタブに差し替え → NG"
reset_unfixed
mkdir -p "$D"
cat >"$D/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/bin/sh -c 'mkdir -p /var/lib/ch04-app; echo OK > /var/lib/ch04-app/status; exec sleep infinity'
EOF
systemctl daemon-reload
expect ng ch04-check
expect_out "NG:"

case_begin "チート: ExecStartPost で status を偽造(未修復のまま)→ NG"
reset_unfixed
mkdir -p "$D"
cat >"$D/override.conf" <<'EOF'
[Service]
ExecStartPost=-/bin/sh -c 'echo OK > /var/lib/ch04-app/status'
EOF
systemctl daemon-reload
expect ng ch04-check
expect_out "NG:"

case_begin "チート: status を chattr +i で固定 → 初期化検証で NG"
reset_unfixed
systemctl stop $U 2>/dev/null
mkdir -p /var/lib/ch04-app
echo OK >"$STATUS"
chattr +i "$STATUS"
expect ng ch04-check
expect_out "NG:"
chattr -i "$STATUS" 2>/dev/null || true
rm -f "$STATUS"

case_begin "その場しのぎ: cgroupfs の memory.max へ直接書き込み → 再起動判定で NG"
reset_unfixed
systemctl restart $U
echo $((256 * 1024 * 1024)) >/sys/fs/cgroup/system.slice/ch04-app.service/memory.max 2>/dev/null || true
expect ng ch04-check
expect_out "NG:"

# 後始末: 未修復状態に戻し、自動判定タイマーを再開する
reset_unfixed
systemctl restart $U
systemctl enable --now handson-autocheck.timer >/dev/null 2>&1 || true
echo
echo "(後始末: 未修復状態に戻し、autocheck timer を再開した)"

e2e_end
