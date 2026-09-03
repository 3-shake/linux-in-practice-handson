#!/usr/bin/python3
#
# 第4章 問題2 のワーカー。作業のために一定量のメモリを必要とする。
# mmap() で領域を確保し、1ページずつ触って(デマンドページングで)物理メモリを
# 実際に割り当ててから、正常稼働に入る。
#
import mmap
import os
import time

REQUIRED = 120 * 1024 * 1024  # このワーカーが作業に必要とするメモリ量
PAGE = 4096
STATUS = "/var/lib/ch04-app/status"


def log(msg):
    print("ch04-app: " + msg, flush=True)


log("起動しました。作業用に %d MiB のメモリを確保して触ります。" % (REQUIRED // (1024 * 1024)))

# mmap() システムコールで無名メモリ領域を確保(この時点では物理メモリ未割り当て)
buf = mmap.mmap(-1, REQUIRED, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)

# デマンドページング: 1ページずつ触って物理メモリを実際に割り当てる
for i in range(0, REQUIRED, PAGE):
    buf[i] = 1

log("作業用メモリの確保に成功しました。正常稼働に入ります。")

os.makedirs(os.path.dirname(STATUS), exist_ok=True)
with open(STATUS, "w") as f:
    f.write("OK\n")

# 稼働継続(ハートビート)
while True:
    time.sleep(30)
    log("正常稼働中")
