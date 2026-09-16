# ハンズオン VM のログイン案内(/etc/profile.d/handson.sh として配置される)。
# ログイン時に章の状態を表示し、start-chapter を「切り替え+その章のディレクトリ
# へ移動」に包み、いま居る章ディレクトリがアクティブでないときだけ再開方法を
# 1行案内する(cd で章を切り替えたりはしない)
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac

command -v handson-status >/dev/null 2>&1 && handson-status

# コマンド本体は子プロセスなので親シェルの cwd を変えられない。関数で包んで
# 切り替え後にその章のディレクトリへ移動する
start-chapter() {
    command start-chapter "$@" || return
    if [[ "${1:-}" =~ ^ch[0-9]{2}$ ]] && [ -d "/opt/handson/$1" ]; then
        cd "/opt/handson/$1" && echo "カレントディレクトリを $PWD に移動しました"
    fi
}

_handson_cd_hint() {
    local ch active key
    if [[ "$PWD" =~ ^/opt/handson/(ch[0-9]{2}) ]]; then
        ch=${BASH_REMATCH[1]}
    else
        _HANDSON_HINTED=""
        return 0
    fi
    active=$(cat /etc/handson/state/active 2>/dev/null)
    # 居場所とアクティブ章の組で案内済みを覚える。居たまま別の章に切り替わったら再案内
    key="$ch:$active"
    [ "$key" = "${_HANDSON_HINTED:-}" ] && return 0
    _HANDSON_HINTED=$key
    [ "$ch" = "$active" ] && return 0
    if [ -e "/etc/handson/state/$ch.installed" ]; then
        echo "ℹ $ch は一時停止中です。再開するには: start-chapter $ch"
    else
        echo "ℹ $ch は未開始です。開始するには: start-chapter $ch"
    fi
}
PROMPT_COMMAND="_handson_cd_hint${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
