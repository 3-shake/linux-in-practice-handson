# 第2章 解説(運営用・ハンズオン実施後に公開予定)

## 問題1: 眠り続けるデーモン

狙い: 「常駐プロセス=デーモン」を `ps ajx` で見分け、動作中のプロセスに `strace -p` で
アタッチして挙動(=システムコールの列)を観測する習慣をつける
(2章「デーモン」「プロセスの親子関係」「プロセスの状態」+ 1章「システムコール発行の可視化」)。

想定解:

```console
# 1) デーモンを見つける。ps ajx の PPID / SID / TTY / STAT を読む
$ ps ajx | grep -w oracled | grep -v grep
  PPID   PID  PGID   SID TTY   TPGID STAT UID  TIME COMMAND
     1  1234  1234  1234 ?        -1 Ss     0  0:00 /opt/handson/ch02/oracled
#  ^PPID=1(親は init)  ^SID=PID(独自セッション)  ^TTY=?(端末なし) = デーモンの特徴

# 2) 動いているプロセスにアタッチして観測する。数秒待てば write が流れる
$ sudo strace -p 1234 -e trace=write -s 64
write(3, "flag{...全体...}", 38) = 38
```

デフォルトの `strace` は文字列を 32 文字で切って `...` にするので、`-s 64` で全体を出す。
`/dev/null` へ書いているので `write` の fd は直前の `openat` の戻り値。

学び: デーモンの見分け方(PPID=1 / SID=PID / TTY=?)、プロセスの状態(ほぼ S、たまに起きて write)、
動作中プロセスへの `strace -p` アタッチ、`write(2)` の引数の読み方、`-s` の必要性。

### 別解(いずれも正解扱い。輪読会で紹介すると盛り上がる)

```console
# デーモンの PID を素早く得る
$ pgrep -af oracled
$ systemctl status handson-ch02-oracled.service   # サービス経由で起動している

# SIGHUP で即座に write させる(デーモンは HUP を「設定再読み込み」の合図に使う慣習。
# oracled は HUP を受けると 1 回 emit する)。sleep を待たずに観測できる
$ sudo strace -p <PID> -e trace=write -s 64 &
$ sudo kill -HUP <PID>

# ltrace でライブラリ関数側から見る(環境により非表示のことあり)
$ sudo ltrace -p <PID> -s 64

# gdb で write システムコールを捕まえ、buf(x86_64 では第2引数 rsi)を読む
$ sudo gdb -p <PID>
(gdb) catch syscall write
(gdb) continue
(gdb) x/38bc $rsi

# 自分で起動して観測する裏技: 端末に直結しないよう isatty を外せば daemon ループに入る
$ /opt/handson/ch02/oracled </dev/null >/dev/null 2>&1 &
$ strace -p $! -e trace=write -s 64   # 自分の子なので sudo 不要

# bpftrace: 実行中プロセスの write を横から観測(SRE 的には一番実務に近い)
$ sudo apt-get install -y bpftrace
$ sudo bpftrace -e 'tracepoint:syscalls:sys_enter_write /comm == "oracled"/
    { printf("%s\n", str(args->buf, args->count)); }'

# 静的解析: .rodata から XOR 済み配列を取り出し、既知平文 "flag{" から鍵 0x5A を割り出して復号
$ objcopy -O binary --only-section=.rodata /opt/handson/ch02/oracled /tmp/r.bin
$ python3 -c "import re;d=open('/tmp/r.bin','rb').read();x=bytes(b^0x5A for b in d);print(re.search(rb'flag\{[0-9a-f]+\}',x).group().decode())"
```

議論ポイント:

- なぜ `strings` で出ないのに `strace` で見えるのか(1章と同じ:XOR 難読化 vs write は
  カーネルへの依頼なので隠せない)。
- `strace -p` に `sudo` が要るのはなぜか → `ptrace` の権限。他人(root)のプロセスに
  アタッチするには権限がいる(`kernel.yama.ptrace_scope`)。
- なぜ `oracled` を自分で叩くと動かないのか → `isatty()`。デーモンは端末を持たない
  (TTY=?)ので、対話端末に直結している=デーモンではない、という判定で弾いている。
- systemd がサービスの main プロセスに `setsid` するので SID=PID になり、教科書どおりの
  デーモンの姿(2章 sshd の例と同じ Ss / ? / PPID=1)になる。

## 問題2: 倒せないプロセス

狙い: シグナルの理解(2章「シグナル」+ コラム「絶対殺す SIGKILL」)。SIGTERM は無視できるが
SIGKILL は無視できないこと、そして「殺しても復活する」現象から管理主体(systemd サービス)に
たどり着くこと。

現象:

```console
$ pgrep -af immortal  # PID を控える
$ kill <PID>          # 無反応
$ sudo kill -9 <PID>; pgrep -af immortal   # 直後は消えている
$ sleep 2; pgrep -af immortal              # 別の PID で戻っている
```

復活間隔はユニットの `RestartSec=1` による(検知後 1 秒待って ExecStart をやり直すので、
python3 の起動を含めて体感 1〜2 秒)。fork し直すので PID は必ず変わる。この「PID が変わる」
が、生き残ったのではなく誰かが作り直している、と気づく最初の手がかり。

原因調査:

```console
# なぜ kill が効かないか
$ grep Sig /proc/<PID>/status
SigIgn: 0000000001005002     # シグナル n は下から n ビット目。bit2(INT)+bit15(TERM)=0x4002 が
                             # immortal.py の設定。残りの 0x1001000(PIPE, XFSZ)は Python 処理系のもの

# 誰が復活させているか。復活後も PPID=1 / TTY=? / SID=PID なので PID 1(systemd)の直下に
# 生えていると推測できるが、二重 fork したデーモンも PPID=1 になるので決め手は cgroup。
# systemd はサービスごとに cgroup を作るので、所属ユニット名がそのまま出る
$ cat /proc/<PID>/cgroup
0::/system.slice/handson-immortal.service
$ systemctl status <PID>     # PID を渡してもユニットに解決してくれる(ps -o unit でも可)

# 復活の理由はユニット定義の Restart=
$ systemctl cat handson-immortal.service
[Service]
ExecStart=/usr/bin/python3 /opt/handson/ch02/immortal.py
Restart=always
...
$ journalctl -b -u handson-immortal.service | grep -i restart   # 裏取り
systemd[1]: handson-immortal.service: Scheduled restart job, restart counter is at 1.
```

想定解(恒久修復):

```console
$ sudo systemctl disable --now handson-immortal.service
$ sudo ch02-check
OK! ... flag{...}
```

`mask --now`(disable より強く、起動そのものを禁止)や、`stop` と `disable` を別々に打つのも
合格。修復できると systemd timer(30秒周期の `ch02-check --auto`)が検知し、wall 通知+
自動提出のうえ timer は自動停止する。

### 合否の原則と不合格パターン

systemd には「今動いている個体」と「起動時に立ち上がる設定(enable = WantedBy の symlink)」
の 2 層があり、check は両方が止まっていること(is-enabled が enabled でない、かつ is-active
が active でない)を要求する。`Restart=` は前者の層の「勝手に死んだときの復旧」設定であって、
後者とは無関係。

| 操作 | is-enabled | is-active | 結果 |
|---|---|---|---|
| `kill -9` だけ | enabled | active(復活) | NG |
| `kill -9` を 10 秒に 5 回以上連打 | enabled | failed(起動レート制限で復活が止まる) | NG。再起動すれば復活 |
| `systemctl stop` だけ | enabled | failed | NG。再起動すれば復活 |
| `systemctl edit` で `Restart=no` にして `kill -9` | enabled | failed | NG。原因の確証には使えるが修復ではない |
| `disable --now` / `mask --now` | disabled / masked | inactive, failed | OK |

議論ポイント:

- SIGTERM は捕捉・無視できるが SIGKILL と SIGSTOP はできない(2章コラム)。だから `kill -9` は
  効く。それでも復活するのは、プロセスに管理主体がいるから。倒すべきは個体ではなく管理主体。
- `Restart=always` なのに `systemctl stop` で止まるのはなぜか → Restart= が発動するのは
  systemd の知らないところでプロセスが終了したとき(外から kill、exit、クラッシュ、タイムアウト)。
  `systemctl stop` は systemd 自身が止める操作なので再起動の対象にならない(systemd.service(5))。
  「always」は「どんな理由の終了でも」であって「stop しても」ではない。
- stop 時、SIGTERM を無視するプロセス相手だと systemd は TimeoutStopSec 経過後に SIGKILL する。
  ここでは `KillSignal=SIGKILL` にして `disable --now` が固まらないようにしている(その結果
  stop 後の状態が inactive ではなく failed になる)。
- 発展: 本物の「絶対死なないプロセス」= uninterruptible sleep(STAT=D)。SIGKILL すら届かない。
  immortal は殺せるが復活するだけなので別物。

## フラグ検証(運営)

提出されたフラグは次で再計算して一致確認する:

```
printf '%s' "<participant>:ch02-q1" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q1
printf '%s' "<participant>:ch02-q2" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q2
```

## 運営メモ: ソースの公開タイミング

参加者に渡すのは EC2 だけ(setup 完了時に /opt/src のソースは自動削除される)。
解説タイムに `src/oracled.c` と `setup.sh` を Slack で公開すると深掘り教材になる:
`isatty` によるデーモン判定、systemd サービスとしての起動、XOR 難読化、
`handson-immortal` の `SIG_IGN` と `Restart=always` の組み合わせが、そのまま章の実例になる。

## 既知の割り切り

- 参加者は sudo を持つため `/etc/handson/flags/ch02-q2` を直接読めば q2 のフラグは取れてしまう。
  README で反則と明記して性善説で運用する(勉強会なので)。q1 のフラグは VM に平文で置いていない
  (バイナリ内は XOR 済み、`answers/` は sha256 のみ)。
- q1 はバイナリを逆アセンブルすれば XOR キーごと読める。それはそれで学びなので正解扱い。
- q1 の oracled は Restart=always なので、参加者が `sudo kill` してもすぐ復活する(観測を邪魔しない)。
- `strace -p` は `ptrace_scope` の既定値では他人のプロセスに sudo が必要。README で sudo を案内済み。
