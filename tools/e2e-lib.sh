# 章の E2E テスト(chapters/chNN/e2e.sh)が VM 上で source する共有ライブラリ。
# tools/e2e が章ファイルと一緒に VM へ送り込み、$E2E_SRC/tools/e2e-lib.sh
# として読み込まれる。
#
# 使い方:
#   case_begin "renice のみ → NG"     # ケースの開始を宣言
#   expect ng ch03-check              # 実行して終了コード(ok=0 / ng=非0)を検証
#   expect_out "再起動テストで"        # 直前の expect の出力に含まれる文字列を検証
#   pass "説明" / fail "説明"          # 自前の判定結果を記録
#   e2e_end                           # 集計して終了(1つでも FAIL なら exit 1)

E2E_FAIL=0
E2E_OUT=""

case_begin() {
    echo
    echo "== case: $1 =="
}

pass() { echo "  -> PASS ($1)"; }

fail() {
    echo "  -> FAIL: $1"
    E2E_FAIL=1
}

# expect <ok|ng> <cmd...>
# コマンドを実行して出力を表示し、終了コードが期待(ok=0 / ng=非0)どおりか検証。
# 出力は E2E_OUT に保存され、expect_out で追加検証できる
expect() {
    local want=$1 rc got
    shift
    E2E_OUT=$("$@" 2>&1)
    rc=$?
    printf '%s\n' "$E2E_OUT" | sed 's/^/  | /'
    got=ng
    [ "$rc" -eq 0 ] && got=ok
    if [ "$got" = "$want" ]; then
        pass "exit=$rc"
    else
        fail "expected $want but exit=$rc"
    fi
}

# 直前の expect の出力に文字列(固定文字列)が含まれるか
expect_out() {
    if printf '%s' "$E2E_OUT" | grep -qF -- "$1"; then
        pass "output contains: $1"
    else
        fail "output does not contain: $1"
    fi
}

e2e_end() {
    echo
    if [ "$E2E_FAIL" -eq 0 ]; then
        echo "E2E: ALL PASS"
    else
        echo "E2E: FAILED"
    fi
    exit "$E2E_FAIL"
}
