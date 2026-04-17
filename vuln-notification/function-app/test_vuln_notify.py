#!/usr/bin/env python3
# ==============================================================
# 脆弱性通知システム - 動作確認用 Python スクリプト (Python 3.12)
# 使用方法:
#   python3 test_vuln_notify.py --function-app-name <NAME> --user-access-token <TOKEN> \
#       --upns analyst01@contoso.com owner01@contoso.com
#   python3 test_vuln_notify.py --function-app-name <NAME> --use-az-graph-token \
#       --upns analyst01@contoso.com owner01@contoso.com
#   python3 test_vuln_notify.py --function-app-name <NAME> --use-az-graph-token \
#       --upns analyst01@contoso.com owner01@contoso.com \
#       --create-planner-task --planner-plan-id <PLAN_ID> --planner-bucket-id <BUCKET_ID>
#
# 依存: 標準ライブラリのみ (urllib)。az CLI がインストール済みであれば --use-az-graph-token を利用可能。
# ==============================================================

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib import error, request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="脆弱性通知システムの動作確認用スクリプト",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--function-app-name", default="", help="Function App 名 (<name>.azurewebsites.net)")
    parser.add_argument("--function-url", default="", help="完全な Function URL (指定時は --function-app-name より優先)")
    parser.add_argument("--user-access-token", default="", help="Entra ユーザートークン")
    parser.add_argument(
        "--use-az-graph-token",
        action="store_true",
        help="az CLI で Microsoft Graph トークンを取得する (検証目的のみ。OBO 前提の API では不可の場合あり)",
    )
    parser.add_argument("--upns", nargs="*", default=[], help="通知対象 UPN (スペース区切り)")
    parser.add_argument("--chat-id", default="", help="既存チャット ID (未指定の場合は新規作成)")
    parser.add_argument("--create-planner-task", action="store_true", help="Planner タスクを作成する")
    parser.add_argument("--planner-plan-id", default="", help="Planner Plan ID")
    parser.add_argument("--planner-bucket-id", default="", help="Planner Bucket ID")
    parser.add_argument("--planner-assignee-upn", default="", help="Planner 担当者 UPN (単一)")
    parser.add_argument("--title", default="", help="通知タイトル")
    parser.add_argument("--message", default="", help="通知メッセージ")
    return parser.parse_args()


def get_az_graph_token() -> str:
    try:
        result = subprocess.run(
            ["az", "account", "get-access-token", "--resource-type", "ms-graph", "--query", "accessToken", "-o", "tsv"],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except FileNotFoundError:
        print("[ERROR] az CLI が見つかりません。Azure CLI をインストールしてください。", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as exc:
        print(f"[ERROR] az account get-access-token 失敗: {exc.stderr.strip()}", file=sys.stderr)
        sys.exit(1)


def build_payload(args: argparse.Namespace, title: str, message: str) -> dict[str, Any]:
    due_date = (datetime.now(timezone.utc) + timedelta(days=7)).strftime("%Y-%m-%d")

    sample_vuln = {
        "cve_id": "CVE-2026-12345",
        "severity": "High",
        "cvss": "9.1",
        "component": "OpenSSL",
        "affected_version": "3.0.0 - 3.0.13",
        "fixed_version": "3.0.14",
        "service": "payments-api",
        "environment": "production",
        "due_date": due_date,
        "reference": "https://nvd.nist.gov/vuln/detail/CVE-2026-12345",
    }

    assignee_upns = [args.planner_assignee_upn] if args.planner_assignee_upn else list(args.upns)

    return {
        "upns": args.upns,
        "chat_id": args.chat_id,
        "title": title,
        "message": message,
        "planner": {
            "enabled": bool(args.create_planner_task),
            "plan_id": args.planner_plan_id,
            "bucket_id": args.planner_bucket_id,
            "assignee_upn": args.planner_assignee_upn,
            "assignee_upns": assignee_upns,
        },
        "facts": {
            "source": "test_vuln_notify.py",
            "targetUserCount": len(args.upns),
            "cve_id": sample_vuln["cve_id"],
            "severity": sample_vuln["severity"],
            "cvss": sample_vuln["cvss"],
            "component": sample_vuln["component"],
            "affected_version": sample_vuln["affected_version"],
            "fixed_version": sample_vuln["fixed_version"],
            "service": sample_vuln["service"],
            "environment": sample_vuln["environment"],
            "due_date": sample_vuln["due_date"],
            "reference": sample_vuln["reference"],
        },
    }, sample_vuln


def post_json(url: str, payload: dict[str, Any], token: str) -> tuple[int, Any]:
    body = json.dumps(payload).encode("utf-8")
    req = request.Request(
        url=url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with request.urlopen(req) as resp:
            status = resp.status
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return status, json.loads(raw)
            except json.JSONDecodeError:
                return status, raw
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw


def main() -> int:
    args = parse_args()

    # ── 環境変数フォールバック ───────────────────────────────
    if not args.upns:
        env_upns = os.environ.get("VULN_NOTIFY_UPNS", "")
        if env_upns:
            args.upns = [u.strip() for u in env_upns.split(",") if u.strip()]
    if not args.planner_plan_id:
        args.planner_plan_id = os.environ.get("VULN_NOTIFY_PLANNER_PLAN_ID", "")
    if not args.planner_bucket_id:
        args.planner_bucket_id = os.environ.get("VULN_NOTIFY_PLANNER_BUCKET_ID", "")
    if not args.planner_assignee_upn:
        args.planner_assignee_upn = os.environ.get("VULN_NOTIFY_PLANNER_ASSIGNEE_UPN", "")
    if not args.user_access_token:
        args.user_access_token = os.environ.get("VULN_NOTIFY_USER_TOKEN", "")

    # ── 必須チェック ──────────────────────────────────────────
    if not args.function_url and not args.function_app_name:
        print("[ERROR] --function-url または --function-app-name を指定してください。", file=sys.stderr)
        return 1

    function_url = args.function_url or f"https://{args.function_app_name}.azurewebsites.net/api/notify"

    if not args.user_access_token and args.use_az_graph_token:
        args.user_access_token = get_az_graph_token()

    if not args.user_access_token:
        print(
            "[ERROR] user-access-token が未指定です。--user-access-token / "
            "VULN_NOTIFY_USER_TOKEN / --use-az-graph-token のいずれかを利用してください。",
            file=sys.stderr,
        )
        return 1

    if not args.upns:
        print("[ERROR] UPN が未指定です。--upns または VULN_NOTIFY_UPNS(カンマ区切り)を設定してください。", file=sys.stderr)
        return 1

    if args.create_planner_task and (not args.planner_plan_id or not args.planner_bucket_id):
        print("[ERROR] Planner タスク作成には --planner-plan-id と --planner-bucket-id が必要です。", file=sys.stderr)
        return 1

    # ── タイトル・メッセージ既定値 ────────────────────────────
    sample_cve = "CVE-2026-12345"
    sample_component = "OpenSSL"
    sample_due = (datetime.now(timezone.utc) + timedelta(days=7)).strftime("%Y-%m-%d")
    title = args.title or f"脆弱性通知: {sample_cve}"
    message = args.message or f"{sample_component} の重大脆弱性を検知しました。修正期限: {sample_due}"

    payload, _ = build_payload(args, title, message)

    # ── リクエスト概要 ────────────────────────────────────────
    print()
    print("================================================")
    print("  脆弱性通知システム - 動作確認")
    print("================================================")
    print(f"  送信先  : {function_url}")
    print(f"  UPN数   : {len(args.upns)}")
    print(f"  chat_id : {args.chat_id or '(新規作成)'}")
    print(f"  Planner : {'有効' if args.create_planner_task else '無効'}")
    if args.create_planner_task:
        print(f"  PlanId  : {args.planner_plan_id}")
        print(f"  BucketId: {args.planner_bucket_id}")
    print("------------------------------------------------")

    status, body = post_json(function_url, payload, args.user_access_token)

    print()
    if 200 <= status < 300:
        print(f"[OK] 通知送信成功 (HTTP {status})")
        if isinstance(body, (dict, list)):
            print(f"  レスポンス: {json.dumps(body, ensure_ascii=False, separators=(',', ':'))}")
        else:
            print(f"  レスポンス: {body}")
        print()
        return 0

    print(f"[ERROR] 送信失敗 (HTTP {status})", file=sys.stderr)
    if isinstance(body, (dict, list)):
        print(f"  詳細: {json.dumps(body, ensure_ascii=False, separators=(',', ':'))}", file=sys.stderr)
    else:
        print(f"  詳細: {body}", file=sys.stderr)
    print()
    return 1


if __name__ == "__main__":
    sys.exit(main())
