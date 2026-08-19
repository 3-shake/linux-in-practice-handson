"""フラグ採点 Lambda(Invoke API で直接呼ばれる)。

組織ポリシーで公開 Function URL が使えないため、VM 内の submit コマンドが
インスタンスロールの SigV4 署名で lambda:InvokeFunction を直接叩く。
イベントは Function URL 互換の {"body": "<JSON文字列>"} 形式で、中身は
{"participant": "...", "flag": "flag{...}"}。

環境変数:
    FLAG_SECRET        setup.sh に渡したものと同じシークレット
    SLACK_WEBHOOK_URL  お祝い投稿先の Slack Incoming Webhook(任意)
    CHAT_WEBHOOK_URL   お祝い投稿先の Google Chat スペース Webhook(任意)

全問題の期待フラグを再計算して照合し、正解なら設定済みの Webhook すべてに
投稿する(Slack も Google Chat も {"text": ...} 形式)。
"""

import hashlib
import hmac
import json
import os
import urllib.request

# (章, 問題ID): (hex 長, 通知での表示名)。章を作るたびにここへ追加する。
QUESTIONS = {
    ("ch01", "q1"): (32, "第1章 問題1「捨てられたフラグ」"),
    ("ch01", "q2"): (16, "第1章 問題2「起動しない greeter」"),
    ("ch02", "q1"): (32, "第2章 問題1「眠り続けるデーモン」"),
    ("ch02", "q2"): (16, "第2章 問題2「倒せないプロセス」"),
    ("ch03", "q1"): (32, "第3章 問題1「気難しい預言者」"),
    ("ch03", "q2"): (16, "第3章 問題2「蘇る CPU 食い」"),
    ("ch04", "q1"): (32, "第4章 問題1「生きているプロセスのメモリ」"),
    ("ch04", "q2"): (16, "第4章 問題2「OOM で死につづけるサービス」"),
    ("ch05", "q1"): (32, "第5章 問題1「無口な郵便屋」"),
    ("ch05", "q2"): (16, "第5章 問題2「消える予約」"),
    ("ch06", "q1"): (32, "第6章 問題1「開かずの金庫」"),
    ("ch06", "q2"): (16, "第6章 問題2「7年前に巻き戻った業務データ」"),
    ("ch07", "q1"): (32, "第7章 問題1「消えたファイルのフラグ」"),
    ("ch07", "q2"): (16, "第7章 問題2「いっぱいなのに空いている cache」"),
    ("ch08", "q1"): (32, "第8章 問題1「幻を映すファイル」"),
    ("ch08", "q2"): (16, "第8章 問題2「書き込みが遅すぎる」"),
    ("ch09", "q1"): (16, "第9章 問題1「ディスクに書かれなかったフラグ」"),
    ("ch09", "q2"): (32, "第9章 問題2「親切すぎるチューナー」"),
    ("ch10", "q1"): (32, "第10章 問題1「消された仮想ディスク」"),
    ("ch10", "q2"): (16, "第10章 問題2「起動しない仮想マシン」"),
    ("ch11", "q1"): (32, "第11章 問題1「別世界の金庫」"),
    ("ch11", "q2"): (16, "第11章 問題2「1回しか動かないコンテナ」"),
    ("ch12", "q1"): (32, "第12章 問題1「秘密は絞られたときだけ」"),
    ("ch12", "q2"): (16, "第12章 問題2「何度でも殺されるワーカー」"),
}


def expected_flag(participant, chapter, qid, length):
    digest = hmac.new(
        os.environ["FLAG_SECRET"].encode(),
        f"{participant}:{chapter}-{qid}".encode(),
        hashlib.sha256,
    ).hexdigest()
    return f"flag{{{digest[:length]}}}"


def notify(text):
    for env in ("SLACK_WEBHOOK_URL", "CHAT_WEBHOOK_URL"):
        url = os.environ.get(env, "")
        if not url:
            continue
        req = urllib.request.Request(
            url,
            data=json.dumps({"text": text}).encode(),
            headers={"Content-Type": "application/json; charset=UTF-8"},
        )
        try:
            urllib.request.urlopen(req, timeout=5)
        except OSError as e:
            # 通知に失敗しても採点結果は返す
            print(f"notify failed ({env}): {e}")


def response(status, body):
    return {"statusCode": status, "body": json.dumps(body, ensure_ascii=False)}


def lambda_handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return response(400, {"result": "error", "message": "invalid json"})

    participant = body.get("participant", "")
    flag = body.get("flag", "")
    if not participant or not flag:
        return response(400, {"result": "error", "message": "participant and flag required"})

    for (chapter, qid), (length, title) in QUESTIONS.items():
        if hmac.compare_digest(flag, expected_flag(participant, chapter, qid, length)):
            notify(f"🎉 *{participant}* さんが {title} を解きました！")
            return response(200, {"result": "correct", "message": f"正解！ {title}"})

    return response(200, {"result": "incorrect", "message": "不正解です。フラグを確認してください。"})
