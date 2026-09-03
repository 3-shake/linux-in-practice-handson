# 第4章 解説(運営用・ハンズオン実施後に公開予定)

## 問題1: 生きているプロセスのメモリ

狙い: 「プロセスのメモリは仮想アドレス空間として存在し、`/proc/<pid>/maps` の各行が
1 つのメモリ領域に対応する」という 4 章の中核概念を、実際に手を動かして体感する。
`mmap()` した無名領域・デマンドページング(VSZ と RSS の差)・コアダンプによる
メモリ内容の取り出し、までを一気通貫でつなげる。

`ch04-keeper` は `mmap(MAP_ANONYMOUS|MAP_PRIVATE)` で 64MiB の無名領域を確保し、
`prctl(PR_SET_VMA_ANON_NAME, ...)` でその領域に `flag_vault` という名前を付け、
復号したフラグを**先頭ページにだけ**書き込んで常駐する。フラグは実行ファイルには
XOR 0x5A 済みの配列としてしか存在せず、実行時にメモリ上で復号される。

### 想定解

```console
# 1. プロセスを見つける。VSZ(仮想)は 64MiB 超なのに RSS(物理)はごく僅か
#    = mmap で確保しただけで、触ったページにしか物理メモリが割り当たっていない
$ ps -o pid,vsz,rss,comm -C ch04-keeper
    PID    VSZ   RSS COMMAND
   1234  68xxx   1xxx ch04-keeper

# 2. /proc/<pid>/maps で、フラグを置いた無名領域を特定する
$ pid=$(pgrep -x ch04-keeper)
$ sudo grep flag_vault /proc/$pid/maps
7fxxxxxxx000-7fxxxxxxx000 rw-p 00000000 00:00 0    [anon:flag_vault]

# 3. プロセスのメモリをコアダンプで丸ごと取り出して grep する
$ sudo gcore -o /tmp/keeper $pid
$ strings /tmp/keeper.$pid | grep -o 'flag{[0-9a-f]*}'
flag{...}

$ submit 'flag{...}'
```

学び: 仮想アドレスと物理アドレスの分離、デマンドページング(mmap 直後は物理メモリ
未割り当て → 触ったページだけ割り当て)、`/proc/<pid>/maps` の読み方、
プロセスのメモリは外から観測・ダンプできること。

### 別解(いずれも正解扱い。輪読会で紹介すると盛り上がる)

`strings ch04-keeper`(実行ファイル)では XOR 難読化のため出てこないが、
「生きたプロセスのメモリ」を覗く手段はいくらでもある:

```console
# gdb で該当領域だけをダンプ(maps で得たアドレス範囲を使う)
$ sudo gdb -p $pid -batch -ex "dump memory /tmp/v 0x7fxxxxxxx000 0x7fxxxxxxx000"
$ strings /tmp/v | grep -o 'flag{[0-9a-f]*}'

# /proc/<pid>/mem を直接読む(maps の開始アドレスへ seek して読み出す)
$ start=0x$(sudo grep flag_vault /proc/$pid/maps | cut -d- -f1)
$ sudo dd if=/proc/$pid/mem bs=1 skip=$((start)) count=4096 2>/dev/null \
    | strings | grep -o 'flag{[0-9a-f]*}'

# gdb でプロセスにアタッチして文字列検索
$ sudo gdb -p $pid -batch -ex "find 0x7fxxxxxxx000, +4096, 'f','l','a','g','{'"

# 静的解析(実行ファイルから復号): .rodata の XOR 済み配列を 0x5A で戻す。
# 鍵は objdump -d の xor $0x5a、または「flag{ で始まる」既知平文から割り出せる
$ objcopy -O binary --only-section=.rodata /opt/handson/ch04/ch04-keeper /tmp/r.bin
$ python3 -c "
import re
x = bytes(b ^ 0x5A for b in open('/tmp/r.bin','rb').read())
print(re.search(rb'flag\{[0-9a-f]+\}', x).group().decode())"
```

`[anon:flag_vault]` という名前は `/proc/<pid>/maps` を読ませるための誘導。
名前でgrepできない環境(古いカーネル)でも、「64MiB の rw-p 無名領域」を探せば
同じ領域にたどり着ける、という話をすると VMA(仮想メモリ領域)の理解が深まる。

## 問題2: OOM で死につづけるサービス

狙い: OOM killer と「プロセスの削除によるメモリの強制回収」(4章)、および
`ps aux` の RSS によるメモリ使用量の観察、デマンドページング(触った分だけ物理メモリを
消費する)を、壊れたサービスの原因調査を通じて体感する。

`ch04-app.service` のワーカーは作業に約 120MiB を必要とし、`mmap()` で確保した領域を
1 ページずつ触って物理メモリを実際に割り当てる。ところが unit の `MemoryMax=64M` が
小さすぎるため、触っている途中で cgroup の OOM killer に殺され、`Restart=on-failure`
で 15 秒ごとに起動と OOM 死を繰り返している。

### 現象と原因調査

```console
$ systemctl status ch04-app
     Active: activating (auto-restart) (Result: oom-kill) ...

$ journalctl -u ch04-app -n 20     # 繰り返し殺されているのが分かる
$ sudo dmesg | grep -i 'out of memory'
... Memory cgroup out of memory: Killed process NNNN (python3) ...

# ワーカーが実際どれだけ物理メモリを使うのか。触っている最中の RSS を観察すると
# 64MiB 付近まで伸びたところで消える(= そこで殺されている)
$ watch -n0.5 'ps -o pid,vsz,rss,comm -C python3'

# どこで上限がかけられているか
$ systemctl show ch04-app -p MemoryMax
MemoryMax=67108864          # 64MiB。ワーカーが必要とする 120MiB に足りない
```

### 想定解(恒久修復)

`MemoryMax` を十分な値(ワーカーの ~120MiB を超える値。例 256M)へ恒久的に引き上げる。

```console
# drop-in で上書きするのが最も行儀が良い(systemctl edit が daemon-reload まで面倒を見る)
$ sudo systemctl edit ch04-app
# エディタに以下を書いて保存:
#   [Service]
#   MemoryMax=256M

$ sudo systemctl restart ch04-app
$ sudo ch04-check
OK! ch04-app は OOM に殺されず正常稼働しています。フラグ: flag{...}
```

修復できると systemd timer(30秒周期の `ch04-check --auto`)が検知し、wall 通知+自動提出
のうえ timer は自動停止する。

### 別解(いずれも合格)

```console
# unit ファイルを直接編集して MemoryMax を書き換える(daemon-reload を忘れずに)
$ sudo sed -i 's/MemoryMax=64M/MemoryMax=256M/' /etc/systemd/system/ch04-app.service
$ sudo systemctl daemon-reload && sudo systemctl restart ch04-app

# set-property(--runtime を付けなければ /etc/systemd/system.control に永続 drop-in が作られる)
$ sudo systemctl set-property ch04-app MemoryMax=256M

# 制限そのものを撤廃する(MemoryMax=infinity、または MemoryMax 行の削除)。合格はするが、
# 暴走時に VM 全体を巻き込むリスクが戻るので「制限を消すのが正解か?」を議論すると
# cgroup の意義が深まる
$ sudo systemctl edit ch04-app     # MemoryMax=infinity

# 専用 slice を作って上位からメモリ枠を与える(unit 自身の MemoryMax=64M は撤去が必要。
# leaf 側の上限が優先されるため)。遠回りだが cgroup 階層の理解が深まる別解
$ sudo tee /etc/systemd/system/ch04.slice <<'EOF'
[Slice]
MemoryMax=256M
EOF
$ sudo sed -i '/^MemoryMax=64M/d; /^\[Service\]/a Slice=ch04.slice' \
    /etc/systemd/system/ch04-app.service
$ sudo systemctl daemon-reload && sudo systemctl restart ch04-app
```

### 判定の仕組み(check は実挙動を測る)

`ch04-check` は設定値や status の文字列ではなく、次の実挙動で合否を決める:

1. status を削除して初期化(削除できなければ chattr/bind mount 等の改ざんとみなし NG)
2. `daemon-reload` + クリーン再起動(その場しのぎの一時状態を消す)
3. worker が OK を書くまで待つ(上限不足なら途中で OOM kill され、永遠に OK にならない)
4. この起動でユニットの cgroup が実際に約 120MiB を使った形跡があるか
   (`/sys/fs/cgroup/<ControlGroup>/memory.peak` ≥ 110MiB。カーネルの実測カウンタなので
   status の偽造やワークロード改変では作れない)
5. OK のあと 5 秒間、同じ MainPID のまま active で status も OK のままか
   (OK を書いた直後に OOM 死する「フラッシュ合格」や別プロセスによる偽造を弾く)

### 不合格になるパターンと議論

| 操作 | 判定 | 弾かれる理由 |
| --- | --- | --- |
| `MemoryMax=100M` など不足した引き上げ | NG | 120MiB を触り切る前に OOM kill(手順3) |
| cgroupfs の `memory.max` へ直接書き込み | NG | 再起動で unit 設定から再適用され消える(手順2)。「なぜ消えるのか」は cgroup と systemd の関係を学ぶ好機 |
| `worker.py` の `REQUIRED` を減らす等のワークロード改変 | NG | memory.peak が閾値に届かない(手順4)。「アプリの仕様」を書き換えるのは修復ではない(下の割り切りも参照) |
| `ExecStart` をメモリを触らないスタブに差し替え | NG | 同上(手順4) |
| `ExecStartPost` 等で status に OK を書く偽造 | NG | memory.peak 不足(手順4)+本物の worker が死ぬと MainPID が変わる(手順5) |
| status を手書き・chattr +i・bind mount で固定 | NG | 初期化検証(手順1)と再起動(手順2) |
| `systemd-run` 等の別 unit/別プロセスで OK を書き続ける | NG | ch04-app 自身の cgroup に実績が残らない(手順4) |

### 議論が深まるポイント

- `sudo systemctl set-property ch04-app MemoryMax=256M --runtime` は `--runtime` を
  付けると `/run` 以下の一時 drop-in になり**再起動で消える**。ch04-check は
  再起動して確認するので合格はするが、これは恒久修復か? → ch01 の
  `ldconfig <dir>`(次に素の ldconfig が走ると消える)と同じ「その場しのぎ問題」。
- 「メモリを増やす」のではなく「ワーカーの使用量を減らす」方向の議論も面白い。本章の
  「同時に動かすプロセス数を減らすか、メモリを増設する」という OOM 対策の話につながる
  (この教材では判定の都合で「上限を直す」だけを合格にしている。割り切り参照)。
- なぜ `free` では見えず cgroup の OOM が起きたのか → システム全体には空きがあっても、
  cgroup 単位の上限(MemoryMax)に達すれば、その cgroup 内だけで OOM killer が動く。
  4章の OOM killer をコンテナ/systemd の文脈へ広げる好例。
- ワーカーは `mmap` で 120MiB 確保しても、触るまで物理メモリを消費しない
  (デマンドページング)。「確保した瞬間」ではなく「触った瞬間」に殺されることを
  RSS の伸びで確認できる。

## フラグ検証(運営)

提出されたフラグは次で再計算して一致確認する:

```
printf '%s' "<participant>:ch04-q1" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q1
printf '%s' "<participant>:ch04-q2" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q2
```

## 運営メモ: ソースの公開タイミング

参加者に渡すのは EC2 だけ(setup 完了時に `/opt/src` のソースは自動削除される)。
`keeper.c` を読まれると Q1 の種明かし(XOR 難読化と mmap でのメモリ配置)になるため、
会の間は非公開にし、実施後にアップロードする。解説タイムに `src/` と `setup.sh` を
Slack で公開すると深掘り教材になる:keeper.c は「なぜ strings で出ないか(XOR)」
「なぜプロセスのメモリから取れるか(仮想アドレス空間は外からダンプできる)」の実例、
worker.py と unit の `MemoryMax` は cgroup OOM の実演そのもの。

> なお `worker.py`(フラグを含まない)は実行に必要なので `/opt/handson/ch04/` に残る。
> これを読まれても Q2 の答え(= MemoryMax を直す)は隠しようがない設計上のもので、
> むしろ「必要メモリ量 120MiB」が読めることは調査のショートカットにしかならない。

## 既知の割り切り

- 参加者は sudo を持つため `/etc/handson/flags/ch04-q2` を直接読めば Q2 のフラグは
  取れてしまう。README で反則と明記して性善説で運用する(勉強会なので)。
- Q1 はバイナリを逆アセンブルすれば XOR キーごと読める。それはそれで学びなので正解扱い。
- Q1 の `[anon:flag_vault]` 命名は `prctl(PR_SET_VMA_ANON_NAME)`(カーネル 5.17+ /
  Ubuntu 24.04 の 6.8 で有効)に依存する。無効な環境では名前が付かないが、その場合でも
  「64MiB の rw-p 無名領域」を探せば回収できるので詰まない。
- Q2 の ch04-check は「クリーン再起動して OK を書けるか」で判定するため、`--runtime` の
  一時 drop-in でも合格する。厳密な「再起動耐性(reboot 後も直っているか)」までは
  検査していない(reboot をハンズオン中に強制しづらいため)。上記の議論ポイント参照。
- Q2 で「ワーカーの使用量を減らす」方向(worker.py の REQUIRED 縮小等)は不合格にしている。
  本物の運用では正当な OOM 対策だが、この教材では worker.py が「アプリの仕様(本来の
  要求量)」であり、それを書き換えると修復とワークロード改変の区別が付かなくなるため。
  輪読会では議論ネタとして扱う。
- `MemoryMax=64M` を `MemoryHigh=64M` に書き換えるとハード上限が消えるので、実挙動
  判定は合格し得る(スワップ無しの t3.micro では激しいスロットリングで完走しない
  可能性が高い)。「ハードとソフトの上限の違い」という学びがあるのでチート扱いしない。
- 「ExecStart を差し替えつつ MemoryMax も引き上げて、偽ワーカーに 120MiB 触らせる」
  合わせ技は検出できない。ただし本物の修復(上限引き上げ)を済ませた上で偽装する動機が
  無いので、性善説の範囲として割り切る。
- 修復の「出口」(systemctl edit の drop-in で値を直す)は ch03 の Nice= と操作が同型。
  ただし調査パート(OOM の痕跡・RSS の観察・cgroup 上限の発見)が本章の学びの本体で、
  出口の新規性より診断の違いを優先してこのままとする。変えるなら「アプリ設定で
  使用量(並列数)を減らす」出口(本の OOM 対策そのもの)が候補だが、判定の再設計が必要。
