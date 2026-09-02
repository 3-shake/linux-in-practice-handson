# ハンズオン VM のログイン案内(/etc/profile.d/handson.sh として配置される)。
# ログイン時に章の状態を表示し、一時停止中・未開始の章ディレクトリに
# cd したときだけ再開方法を1行案内する(cd で章を切り替えたりはしない)
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

command -v handson-status >/dev/null 2>&1 && handson-status

_handson_cd_hint() {
    local ch active
    if [[ "$PWD" =~ ^/opt/handson/(ch[0-9]{2}) ]]; then
        ch=${BASH_REMATCH[1]}
    else
        _HANDSON_HINTED=""
        return 0
    fi
    [ "$ch" = "${_HANDSON_HINTED:-}" ] && return 0
    _HANDSON_HINTED=$ch
    active=$(cat /etc/handson/state/active 2>/dev/null)
    [ "$ch" = "$active" ] && return 0
    if [ -e "/etc/handson/state/$ch.installed" ]; then
        echo "ℹ $ch は一時停止中です。再開するには: start-chapter $ch"
    else
        echo "ℹ $ch は未開始です。開始するには: start-chapter $ch"
    fi
}
PROMPT_COMMAND="_handson_cd_hint${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
