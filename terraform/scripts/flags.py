#!/usr/bin/env python3
"""Terraform の external data source から呼ばれ、人別フラグを事前計算する。

VM に FLAG_SECRET を渡さないための仕組み(user-data は IMDS 経由で参加者本人が
読めるため、シークレットを渡すと他人のフラグを偽造できてしまう)。
grader/lambda_function.py と同じ HMAC 計算。
"""

import hashlib
import hmac
import json
import sys


def main():
    query = json.load(sys.stdin)
    questions = json.loads(query["questions"])
    out = {}
    for qid, length in questions.items():
        digest = hmac.new(
            query["secret"].encode(),
            f'{query["participant"]}:{query["chapter"]}-{qid}'.encode(),
            hashlib.sha256,
        ).hexdigest()
        out[qid] = f"flag{{{digest[: int(length)]}}}"
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
