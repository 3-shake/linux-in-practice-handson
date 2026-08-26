#!/usr/bin/python3
# 日次集計ジョブ(ダミーの固定計算)。この VM の運用設計では論理CPU0 を
# 対話作業用に空けてあるため、集計は論理CPU1 に固定して行う。
import os
import time

os.sched_setaffinity(0, {1})

NLOOP = 200000000
start = time.time()
for _ in range(NLOOP):
    pass
print(f"集計おわり: {time.time() - start:.1f} 秒")
