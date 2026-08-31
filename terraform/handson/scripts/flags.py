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

# フラグの hex 長は全問題で共通(各章の setup.sh・grader の HEX_LEN と揃える)
HEX_LEN = 32


def main():
    query = json.load(sys.stdin)
    qids = json.loads(query["questions"])
    out = {}
    for qid in qids:
        digest = hmac.new(
            query["secret"].encode(),
            f'{query["participant"]}:{query["chapter"]}-{qid}'.encode(),
            hashlib.sha256,
        ).hexdigest()
        out[qid] = f"flag{{{digest[:HEX_LEN]}}}"
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
