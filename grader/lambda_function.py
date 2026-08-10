"""フラグ採点 Lambda(Function URL で公開する)。

環境変数:
    FLAG_SECRET        setup.sh に渡したものと同じシークレット
    SLACK_WEBHOOK_URL  お祝い投稿先の Incoming Webhook

VM 内の submit コマンドから {"participant": "...", "flag": "flag{...}"} が
POST される。全問題の期待フラグを再計算して照合し、正解なら Slack に投稿する。
"""

import hashlib
import hmac
import json
import os
import urllib.request

# (章, 問題ID): (hex 長, Slack 表示名)。章を作るたびにここへ追加する。
QUESTIONS = {
    ("ch01", "q1"): (32, "第1章 問題1「捨てられたフラグ」"),
    ("ch01", "q2"): (16, "第1章 問題2「起動しない greeter」"),
}


def expected_flag(participant, chapter, qid, length):
    digest = hmac.new(
        os.environ["FLAG_SECRET"].encode(),
        f"{participant}:{chapter}-{qid}".encode(),
        hashlib.sha256,
    ).hexdigest()
    return f"flag{{{digest[:length]}}}"


def post_slack(text):
    req = urllib.request.Request(
        os.environ["SLACK_WEBHOOK_URL"],
        data=json.dumps({"text": text}).encode(),
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=5)


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
            post_slack(f":tada: *{participant}* さんが {title} を解きました！")
            return response(200, {"result": "correct", "message": f"正解！ {title}"})

    return response(200, {"result": "incorrect", "message": "不正解です。フラグを確認してください。"})
