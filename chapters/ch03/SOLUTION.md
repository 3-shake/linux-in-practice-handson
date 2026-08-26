# 第3章 解説（運営用・ハンズオン実施後に公開予定）

## 問題1: 気難しい預言者

狙い: 「プロセスがどの論理CPUで、どんな優先度で動くか」は外から制御できることを
体で覚える（3章「複数の論理CPUを使う場合（taskset）」「タイムスライスの仕組み（nice値）」）。
oracle は起動時に `sched_getaffinity(2)` と `getpriority(2)` で自分の実行のされ方を調べ、

1. 動ける論理CPUが「CPU0 の1つだけ」に縛られている（本の実験プログラムが
   `taskset -p -c 0 $$` や `os.sched_setaffinity(0, {0})` でやっていたことと同じ）
2. nice 値が 10 以上（メッセージは「いちばん低く」と言うので想定は 19）

の両方を満たしたときだけフラグを復号して表示する。

想定解:

```
$ /opt/handson/ch03/oracle
私は気分屋の預言者。論理CPUの間をふらふらと移されるのは好かん。
(いま私が動ける論理CPU: 0 1)

$ taskset -c 0 /opt/handson/ch03/oracle
場所は気に入った。だが私は、急かされるのも好かん。
(いまの私の nice 値: 0)

$ nice -n 19 taskset -c 0 /opt/handson/ch03/oracle
……よかろう。論理CPU0 の上で、静かに思い出すとしよう。
(数秒かかる。その間に別の端末で sar -P ALL 1 を眺めると、私の働きぶりが見える)
これが預言だ: flag{...}
```

`taskset -c 0 nice -n 19 ...` の順でもよい。待ち時間に別端末で `sar -P ALL 1` を見ると
CPU0 の `%nice` が 100 になる（本章の sar の実験の再現。%user ではないのがポイント）。

学び: taskset / nice の使い方、affinity と優先度はプロセスの属性であること、
%user と %nice の違い、優先度を「下げる」のは誰でもできること。

### 別解・議論ポイント

```console
# 実行してから縛る(oracle は起動時にしか検査しないので今回は通らないが、
# taskset -p / renice という「動いているプロセスに後から効かせる」道具の紹介になる)
$ taskset -p -c 0 <PID>
$ renice -n 19 -p <PID>

# 条件を探る別ルート: strace で oracle が何を調べているかを見る(1章の復習)
$ strace -e trace=sched_getaffinity,getpriority /opt/handson/ch03/oracle

# 静的解析での短絡(ch01 と同様、それも学びなので正解扱い)
# .rodata の XOR 済み配列を鍵 0x37(objdump -d に xor $0x37 が居る)で復号できる
$ objcopy -O binary --only-section=.rodata /opt/handson/ch03/oracle /tmp/rodata.bin
$ python3 -c "
import re
data = open('/tmp/rodata.bin', 'rb').read()
x = bytes(b ^ 0x37 for b in data)
print(re.search(rb'flag\{[0-9a-f]+\}', x).group().decode())"
```

議論が深まるポイント:

- なぜ `nice -n 19` は root 不要で `nice -n -20` は root が要るのか
  （優先度を「上げる」のは特権。試すと `nice: cannot set niceness: Permission denied`）
- oracle が要求するのは「CPU0 **だけ**」であること。`taskset -c 0,1` では不合格。
  「1つの論理CPUに縛る」= 本章の multiload.sh（デフォルトで1論理CPU）の状況を手で作っている
- 預言者の計算中に `time` を付けると real ≒ user、sys ≒ 0（load.py と同じ CPU バウンド）。
  さらに同じ CPU0 に `taskset -c 0 /opt/handson/ch03/load.py` をぶつけると real だけ伸びる
  （タイムスライスの奪い合い）

## 問題2: CPU を譲らない同居人

狙い: 「CPU を食うプロセスがいて困る」への恒久対応は、殺すことだけではないと体で覚える。
犯人の perfsyncd は「業務上必要なサービス」という建て付けなので、ch02 のように
disable では解決できない。本章の語彙（nice 値 = タイムスライスの配分）で共存させ、
systemd の drop-in（`systemctl edit`）で恒久化する。ch02 問題2と入口は同じ
（犯人を探して unit にたどり着く）だが、出口が正反対（止める → 止めずに譲らせる）。

仕込み: `perfsync.service`（Description は Performance data sync daemon）が
`taskset -c 1` で `perfsyncd` を nice 0 のまま起動している。perfsyncd は
busy 60ms + sleep 40ms のデューティサイクルで論理CPU1 を約6割使う
（100% 張り付きにしないのは、現実の「重い同期処理」に寄せるためと、
バーストクレジットの消費を抑えるため）。被害者の集計ジョブ `report`（nice 0、
論理CPU1 固定）は、同じ nice 0 の perfsyncd と busy 区間のタイムスライスを折半する
ため約 1.4 倍遅くなる。Restart=always + StartLimitIntervalSec=0 なので、kill や
restart を何度繰り返しても 3 秒で蘇る（start-limit で止まらない）。

現象と調査:

```
$ time /opt/handson/ch03/report   # 平常時より 1.4 倍ほど遅い
$ top                             # report 実行中に見ると perfsyncd と CPU を分け合っている
$ ps -eo pid,ni,psr,comm | grep -E 'perfsyncd|report'
 1234   0   1 perfsyncd           # nice 0 で論理CPU1 固定 = report と同じ CPU・同じ優先度
 5678   0   1 report
$ sar -P ALL 1 1                  # CPU1 の %user が高い(nice 0 なので %nice ではない)
$ systemctl status 1234           # ← PID を渡すと所属 unit が分かる
● perfsync.service - Performance data sync daemon
$ systemctl cat perfsync.service  # taskset -c 1 / Restart=always。Nice= の指定なし(=0)
```

想定解（止めずに、譲らせる）:

```
$ sudo systemctl edit perfsync.service    # drop-in を作る(保存すると daemon-reload も自動)
[Service]
Nice=19

$ sudo systemctl restart perfsync.service # 動作中のプロセスに反映
$ time /opt/handson/ch03/report           # 平常の速さに戻る
$ sudo ch03-check
OK! 同期デーモンは CPU を譲るようになり、集計ジョブは平常に戻りました。フラグ: flag{...}
```

修復できると systemd timer（30秒周期の `ch03-check --auto`）が検知し、wall 通知+自動提出
のうえ timer は自動停止する。判定は「service が active のまま」「enabled のまま」
「動作中の perfsyncd の実効 nice 値 ≥ 10」の3点がそろったら、最後に check 自身が
service を再起動して nice 値が維持されるか（＝恒久性）を実測する
（しきい値 10 は q1 の oracle と同じ緩さ。想定解は 19。設定値ではなく再起動後の
実挙動を見るので、`Nice=` でも ExecStart に nice を挟む方式でも通る）。

### 別解（いずれも合格）

```console
# drop-in を手で書く(systemctl edit と同じ結果。daemon-reload を忘れずに)
$ sudo mkdir -p /etc/systemd/system/perfsync.service.d
$ printf '[Service]\nNice=19\n' | sudo tee /etc/systemd/system/perfsync.service.d/override.conf
$ sudo systemctl daemon-reload && sudo systemctl restart perfsync.service

# unit 本体(/etc/systemd/system/perfsync.service)に Nice=19 を書き足しても可。
# drop-in との違い(本体は更新で上書きされ得る、変更点が分離されない)は議論ネタになる

# ExecStart に nice を挟む(既存の taskset と同じ流儀なので自然な発想)。
# drop-in で ExecStart を上書きするときは、いったん空の ExecStart= で
# リセットしてから書く、という systemd の作法も学べる
[Service]
ExecStart=
ExecStart=/usr/bin/nice -n 19 /usr/bin/taskset -c 1 /usr/local/lib/ch03/perfsyncd

# renice + drop-in の合わせ技(restart しない派)。renice は「いま」を、
# drop-in は「これから」を直している、という整理がそのまま学びになる
$ sudo renice -n 19 -p "$(systemctl show -p MainPID --value perfsync.service)"
$ sudo systemctl edit perfsync.service   # Nice=19 を書く
```

不合格になるパターンと、そこから広がる議論:

- `sudo renice -n 19 -p <PID>` だけ → check の再起動テストで nice 0 に戻って落ちる。
  自動判定が 30 秒ごとに走っているので、renice しただけだと間もなく巻き戻される
  （「一時しのぎは戻る」を体験させる仕掛け）。ch02 と同じ「恒久対応とは何か」を、
  今度は殺さない道具で問い直す
- drop-in を書いただけ（restart 忘れ）→ 設定は 19 だが動作中のプロセスは 0 のまま。
  「unit の設定」と「実行中のプロセスの状態」は別物、という systemd 運用の基本
- `systemctl stop / disable / mask`、unit 削除 → 業務上必要なサービスを止めたので NG。
  check がその旨を指摘して押し戻す（ch02 の反射で撃つと叱られる、という仕掛け）
- `kill` → 3 秒後に nice 0 のまま蘇るだけ
- `taskset -p -c 0 <PID>` や CPUAffinity=0 で CPU0 へ引っ越させる → report は速くなるが、
  今度は対話作業（や預言者）と衝突する。check は nice を見るので不合格だが、
  「引っ越しか、優先度か」は実務でも分かれ道になる良い議論ネタ

議論が深まるポイント:

- 修復後も top の perfsyncd は約 60% のまま。nice は「混んだときの配分」であって上限では
  ない（暇な CPU では nice 19 でも使い放題）。上限を課す道具は CPUQuota=（cgroup）だが、
  それは後の章のお楽しみ
- 修復前は sar の CPU1 が %user に、修復後は %nice に計上される。本章の sar の実験の
  before/after を自分の手で作れる（q1 と合わせると「%nice を見たら誰かが nice を
  設定している」と読めるようになる）
- report 実行中は perfsyncd の %CPU が約 30% に落ちる（busy 区間を折半するため）。
  %CPU は「そのプロセスの意思」ではなくスケジューラの配分結果、という見方の練習
- q2 を直す前に q1 の預言者を CPU1 で動かしていたら: nice 19 の oracle は nice 0 の
  perfsyncd にほぼ譲りっぱなしになり、預言が数倍遅くなる。oracle が CPU0 を指定してくる
  のはこの事故を避けるための出題上の采配、という種明かしも面白い
- report が論理CPU1 に固定されているのは「CPU0 は対話用に空ける」という運用設計
  （という建て付け）。taskset / CPUAffinity / sched_setaffinity の実例でもある

## フラグ検証（運営）

提出されたフラグは次で再計算して一致確認する:

```
printf '%s' "<participant>:ch03-q1" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q1
printf '%s' "<participant>:ch03-q2" | openssl dgst -sha256 -hmac "$FLAG_SECRET" -r | cut -c1-32   # q2
```

## 運営メモ

- `terraform.tfvars` は `chapter = "ch03"` に更新する。
  採点サーバーを使う場合は `grader/lambda_function.py` の QUESTIONS への追加も忘れずに
- 参加者に渡すのは EC2 だけ（setup 完了時に /opt/src のソースは自動削除される）。
  解説タイムに `src/` と `setup.sh` を公開すると、oracle.c は sched_getaffinity /
  getpriority の実例、perfsyncd.c はデューティサイクル型の負荷のかけ方、
  perfsync.service + drop-in は「unit の設定をどこで上書きするか」の教材になる
- perfsyncd は修復の前後を問わず論理CPU1 の約6割を使い続ける（nice は配分であって
  上限ではないので、修復しても CPU 使用量は減らない）。t3.micro はデフォルト unlimited
  なので動作に支障はないが、1台あたり 3 円/時間程度の CPU クレジット課金が上乗せされ得る
  （2時間の会なら誤差）。会の後は速やかに destroy する。なおスタンダードモードにすると
  課金は抑えられるが、T3 は起動時クレジットがないためベースライン（合計 20%）に即throttle
  され、q1 の預言も q2 の観察も壊れるので採用しない

## 既知の割り切り

- 参加者は sudo を持つため `/etc/handson/flags` を直接読めば q2 のフラグは取れてしまう。
  README で反則と明記して性善説で運用する（勉強会なので）
- q1 はバイナリを逆アセンブルすれば XOR キーごと読めるし、gdb で条件分岐を飛ばすこともできる。
  それはそれで学びなので正解扱い
- q2 の判定は report の所要時間を実測しない（バーストインスタンスでは時間計測が不安定な
  ため）。perfsync.service の active / enabled と動作中プロセスの nice 値を見たうえで、
  最後に check 自身が service を再起動して nice が維持されるか（恒久性）を実測する。
  このため「合格の直前」と「renice だけした直後」には check がサービスを再起動する
  副作用がある（手動実行時はその旨を表示する）
- 思想としては CPUQuota=（上限を課す）や CPUAffinity=（引っ越し）、
  CPUSchedulingPolicy=idle（nice よりさらに徹底して譲る）でも report は救えるが、
  check は本章の道具である nice に限定して不合格にする。解説タイムで拾う
- 「新しい高負荷プロセスを自分で起動して放置」など自爆的な行為までは検知しない
- oracle の計算量は固定（約 20 億ループ）なので、所要時間はおおよそ数秒だが環境負荷により変動する
