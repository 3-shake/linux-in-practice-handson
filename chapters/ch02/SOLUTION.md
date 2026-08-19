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

狙い: シグナルの理解(2章「シグナル」+ コラム「絶対殺す SIGKILL」)。SIGTERM は
シグナルハンドラで無視できるが SIGKILL は無視できないこと、そして「殺しても復活する」
現象からプロセスの管理主体(systemd サービス)にたどり着くこと。

現象:

```console
$ kill <PID>          # 無反応(immortal.py が SIGTERM を SIG_IGN にしている)
$ sudo kill -9 <PID>  # 消えるが、Restart=always で 1〜2 秒後に別 PID で復活
```

原因調査:

```console
$ cat /proc/<PID>/status | grep Sig
SigIgn: 0000000001005002     # bit2(SIGINT)と bit15(SIGTERM)が無視設定
# シグナル n は下から n ビット目。0x4002 が immortal.py の設定した INT+TERM。
# 残りの 0x1001000(SIGPIPE=13, SIGXFSZ=25)は Python 処理系が起動時に無視するもの
# systemd のサービスであることに気づく(kill -9 後も active のまま Main PID だけ変わる。
# 直近ログにも "Scheduled restart job" が出る)
$ systemctl status handson-immortal.service
● handson-immortal.service - handson immortal (ch02 q2)
     Loaded: loaded (/etc/systemd/system/handson-immortal.service; enabled; ...)
     Active: active (running) ...

# ユニットファイルを見て Restart=always が原因だと分かる
# (systemctl show -p Restart handson-immortal.service でも可)
$ systemctl cat handson-immortal.service
[Service]
ExecStart=/usr/bin/python3 /opt/handson/ch02/immortal.py
Restart=always
...
```

想定解(恒久修復):

```console
$ sudo systemctl disable --now handson-immortal.service
$ sudo ch02-check
OK! ... flag{...}
```

修復できると systemd timer(30秒周期の `ch02-check --auto`)が検知し、wall 通知+自動提出
のうえ timer は自動停止する。

### 別解(いずれも合格)

```console
# mask にすると起動そのものを禁止できる(disable より強い)
$ sudo systemctl mask --now handson-immortal.service

# stop してから disable でも可(--now は stop+disable の一括)
$ sudo systemctl stop handson-immortal.service && sudo systemctl disable handson-immortal.service
```

不合格になる「一時しのぎ」と、その理由:

```console
# kill / kill -9 だけ: サービスは enabled のまま Restart=always で復活 → is-active=active に戻る
$ sudo kill -9 <PID>
# systemctl stop だけ: is-active=failed(KillSignal=SIGKILL で非クリーン終了扱い)に
#   なるが is-enabled=enabled のまま
#   → 再起動で復活する「恒久でない」修復なので check は弾く(is-enabled を見ている)
$ sudo systemctl stop handson-immortal.service
```

判定は「enabled でない(disabled/masked)」かつ「active でない」の両方を要求している。
`kill` 系だけでは前者を満たせず、`stop` だけでは後者しか満たせないので、いずれも不合格。

議論ポイント:

- SIGTERM(`kill` のデフォルト)は捕捉・無視できるが、SIGKILL と SIGSTOP は捕捉も無視も
  できない(2章コラム)。だから `kill -9` は効く。
- では `kill -9` で効くのになぜ復活するのか → プロセスには「管理主体」がいる。systemd の
  `Restart=always`。プロセス単体を殺すのではなく、管理主体ごと止める(disable/mask)。
- systemd がサービスを止めるときも、SIGTERM を無視するプロセス相手だと TimeoutStopSec 経過後
  SIGKILL する。ここでは `KillSignal=SIGKILL` にして `disable --now` が固まらないようにしている。
- 発展: 本物の「絶対死なないプロセス」= uninterruptible sleep(STAT=D)。ディスク I/O 待ちなどで
  SIGKILL すら届かない。これは今回の immortal とは別物(immortal は殺せるが復活するだけ)。

## フラグ検証(運営)

提出されたフラグは次で再計算して一致確認する:

```
printf '%s' "<participant>:ch02-q1" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q1
printf '%s' "<participant>:ch02-q2" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-16   # q2
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
