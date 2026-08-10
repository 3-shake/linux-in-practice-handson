# 第1章 解説(運営用・ハンズオン実施後に公開予定)

## 問題1: 捨てられたフラグ

狙い: 「プログラムの挙動 = システムコールの列」として観察する習慣をつける(1章「システムコール発行の可視化」)。

想定解:

```
$ strace /opt/handson/ch01/oracle
...
openat(AT_FDCWD, "/dev/null", O_WRONLY) = 3
write(3, "flag{0123456789abcdef0123456789a"..., 38) = 38
```

デフォルトでは文字列が 32 文字で切られて `...` になるので、`-s` オプションを調べて

```
$ strace -s 64 /opt/handson/ch01/oracle
write(3, "flag{...全体...}", 38) = 38
```

で全体を得る。`-e trace=write` で write だけに絞る解法も可。

学び: strace の基本、write(2) の引数の読み方、fd 3 が直前の openat の戻り値であること。

### 別解(いずれも正解扱い。輪読会で紹介すると盛り上がる)

`strings` では XOR 難読化のため出てこないが、観測手段はいくらでもある:

```console
# ltrace: write はライブラリ関数でもあるので引数が見える(環境により非表示のことあり)
$ ltrace -s 64 /opt/handson/ch01/oracle

# gdb: write システムコールで止めて buf(x86_64 では第2引数 = rsi)を読む
$ gdb -q /opt/handson/ch01/oracle
(gdb) catch syscall write
(gdb) run
(gdb) x/38bc $rsi

# 静的解析: .rodata から XOR 済み配列を取り出して復号する。
# 鍵 0x5A は逆アセンブル(objdump -d に xor $0x5a が居る)で見つけるか、
# 「フラグは flag{ で始まる」という既知平文から enc[0] ^ 'f' で割り出せる
$ objcopy -O binary --only-section=.rodata /opt/handson/ch01/oracle /tmp/rodata.bin
$ python3 -c "
import re
data = open('/tmp/rodata.bin', 'rb').read()
x = bytes(b ^ 0x5A for b in data)
print(re.search(rb'flag\{[0-9a-f]+\}', x).group().decode())"

# bpftrace: 実行中プロセスの write を「横から」観測(SRE 的には一番実務に近い)
$ sudo bpftrace -e 'tracepoint:syscalls:sys_enter_write /comm == "oracle"/
    { printf("%s\n", str(args->buf, args->count)); }' &
$ /opt/handson/ch01/oracle
```

## 問題2: 起動しない greeter

狙い: 共有ライブラリの動的リンクと ld.so の探索パスの理解(1章「静的ライブラリと共有ライブラリ」)。

現象:

```
$ /opt/handson/ch01/greeter
/opt/handson/ch01/greeter: error while loading shared libraries: libgreet.so.1:
cannot open shared object file: No such file or directory
```

想定解:

```
$ ldd /opt/handson/ch01/greeter
        libgreet.so.1 => not found
$ sudo find / -name 'libgreet*' 2>/dev/null
/opt/handson/ch01/lib/libgreet.so.1
$ echo /opt/handson/ch01/lib | sudo tee /etc/ld.so.conf.d/handson.conf
$ sudo ldconfig
$ sudo ch01-check
OK! ... flag{...}
```

修復できると systemd timer(30秒周期の `ch01-check --auto`)が検知し、wall 通知+自動提出
のうえ timer は自動停止する。

### 別解(いずれも合格)

```console
# /usr/local/lib へコピー(FHS 的に無難な運用)
$ sudo cp /opt/handson/ch01/lib/libgreet.so.1 /usr/local/lib/ && sudo ldconfig

# rpath をバイナリに焼き込む
$ sudo apt-get install -y patchelf
$ sudo patchelf --set-rpath /opt/handson/ch01/lib /opt/handson/ch01/greeter

# ディレクトリ指定の ldconfig(キャッシュに直接載る)
# ※ 恒久対策としては微妙: 次に素の ldconfig が走ると消える。合格にはなるので
#   「これは恒久か?」を議論すると ld.so.cache の理解が深まる
$ sudo ldconfig /opt/handson/ch01/lib
```

`LD_LIBRARY_PATH` は check が `env -i` で実行するため不合格 → 「なぜ落ちるのか」を
議論すると ld.so の探索順(rpath → LD_LIBRARY_PATH → ld.so.cache → デフォルト)の話につながる。

## フラグ検証(運営)

提出されたフラグは次で再計算して一致確認する:

```
printf '%s' "<participant>:ch01-q1" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q1
printf '%s' "<participant>:ch01-q2" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-16   # q2
```

## 運営メモ: ソースの公開タイミング

参加者に渡すのは EC2 だけ(setup 完了時に /opt/src のソースは自動削除される)。
リポジトリには SOLUTION.md と先の章のネタバレが含まれるため、会の間は非公開にし、
ハンズオン実施後にアップロードする想定。

解説タイムにその章の `src/` と `setup.sh` を Slack で公開すると深掘り教材になる:
oracle.c は「なぜ strings で出ないか(XOR)」「なぜ strace で見えるか(write は
カーネルへの依頼だから隠せない)」の説明そのものだし、setup.sh のビルドコマンドは
soname と探索パスの壊し方=共有ライブラリの仕組みの実例になっている。

## 既知の割り切り

- 参加者は sudo を持つため `/etc/handson/flags` を直接読めば q2 のフラグは取れてしまう。
  README で反則と明記して性善説で運用する(勉強会なので)。
- q1 はバイナリを逆アセンブルすれば XOR キーごと読める。それはそれで学びなので正解扱い。
