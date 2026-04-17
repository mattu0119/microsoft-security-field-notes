#!/usr/bin/env bash
# ==============================================================
# 脆弱性通知システム - 動作確認用 Bash スクリプト
# 使用方法:
#   ./test-vuln-notify.sh --function-app-name <NAME> --user-access-token <TOKEN> \
#       --upns analyst01@contoso.com,owner01@contoso.com
#   ./test-vuln-notify.sh --function-app-name <NAME> --use-az-graph-token \
#       --upns analyst01@contoso.com,owner01@contoso.com
#   ./test-vuln-notify.sh --function-app-name <NAME> --use-az-graph-token \
#       --upns analyst01@contoso.com,owner01@contoso.com \
#       --create-planner-task --planner-plan-id <PLAN_ID> --planner-bucket-id <BUCKET_ID>
#
# 依存: bash 4.x 以上 / curl / jq / (オプション) az CLI
# ==============================================================

set -euo pipefail

# ── 既定値 ─────────────────────────────────────────────────────
FUNCTION_APP_NAME=""
FUNCTION_URL=""
USER_ACCESS_TOKEN="${VULN_NOTIFY_USER_TOKEN:-}"
USE_AZ_GRAPH_TOKEN="false"
UPNS_CSV="${VULN_NOTIFY_UPNS:-}"
CHAT_ID=""
CREATE_PLANNER_TASK="false"
PLANNER_PLAN_ID="${VULN_NOTIFY_PLANNER_PLAN_ID:-}"
PLANNER_BUCKET_ID="${VULN_NOTIFY_PLANNER_BUCKET_ID:-}"
PLANNER_ASSIGNEE_UPN="${VULN_NOTIFY_PLANNER_ASSIGNEE_UPN:-}"
TITLE=""
MESSAGE=""

# ── 引数パース ─────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --function-app-name <NAME>    Function App 名 (<name>.azurewebsites.net)
  --function-url <URL>          完全な Function URL (指定時は優先)
  --user-access-token <TOKEN>   Entra ユーザートークン
  --use-az-graph-token          az CLI で Graph トークンを取得
  --upns <CSV>                  通知対象 UPN (カンマ区切り)
  --chat-id <ID>                既存チャット ID (未指定時は新規作成)
  --create-planner-task         Planner タスクを作成する
  --planner-plan-id <ID>        Planner Plan ID
  --planner-bucket-id <ID>      Planner Bucket ID
  --planner-assignee-upn <UPN>  Planner 担当者 UPN
  --title <TEXT>                通知タイトル
  --message <TEXT>              通知メッセージ
  -h, --help                    ヘルプを表示
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --function-app-name)     FUNCTION_APP_NAME="$2"; shift 2 ;;
        --function-url)          FUNCTION_URL="$2"; shift 2 ;;
        --user-access-token)     USER_ACCESS_TOKEN="$2"; shift 2 ;;
        --use-az-graph-token)    USE_AZ_GRAPH_TOKEN="true"; shift ;;
        --upns)                  UPNS_CSV="$2"; shift 2 ;;
        --chat-id)               CHAT_ID="$2"; shift 2 ;;
        --create-planner-task)   CREATE_PLANNER_TASK="true"; shift ;;
        --planner-plan-id)       PLANNER_PLAN_ID="$2"; shift 2 ;;
        --planner-bucket-id)     PLANNER_BUCKET_ID="$2"; shift 2 ;;
        --planner-assignee-upn)  PLANNER_ASSIGNEE_UPN="$2"; shift 2 ;;
        --title)                 TITLE="$2"; shift 2 ;;
        --message)               MESSAGE="$2"; shift 2 ;;
        -h|--help)               usage; exit 0 ;;
        *)
            echo "[ERROR] 不明なオプション: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# ── 依存ツールチェック ─────────────────────────────────────────
for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] $cmd が見つかりません。インストールしてください。" >&2
        exit 1
    fi
done

# ── 必須チェック ───────────────────────────────────────────────
if [[ -z "$FUNCTION_URL" && -z "$FUNCTION_APP_NAME" ]]; then
    echo "[ERROR] --function-url または --function-app-name を指定してください。" >&2
    exit 1
fi

if [[ -z "$FUNCTION_URL" ]]; then
    FUNCTION_URL="https://${FUNCTION_APP_NAME}.azurewebsites.net/api/notify"
fi

if [[ -z "$USER_ACCESS_TOKEN" && "$USE_AZ_GRAPH_TOKEN" == "true" ]]; then
    if ! command -v az >/dev/null 2>&1; then
        echo "[ERROR] az CLI が見つかりません。Azure CLI をインストールしてください。" >&2
        exit 1
    fi
    USER_ACCESS_TOKEN=$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv)
fi

if [[ -z "$USER_ACCESS_TOKEN" ]]; then
    echo "[ERROR] user-access-token が未指定です。--user-access-token / VULN_NOTIFY_USER_TOKEN / --use-az-graph-token のいずれかを利用してください。" >&2
    exit 1
fi

if [[ -z "$UPNS_CSV" ]]; then
    echo "[ERROR] UPN が未指定です。--upns または VULN_NOTIFY_UPNS(カンマ区切り)を設定してください。" >&2
    exit 1
fi

if [[ "$CREATE_PLANNER_TASK" == "true" ]]; then
    if [[ -z "$PLANNER_PLAN_ID" || -z "$PLANNER_BUCKET_ID" ]]; then
        echo "[ERROR] Planner タスク作成には --planner-plan-id と --planner-bucket-id が必要です。" >&2
        exit 1
    fi
fi

# ── UPN を JSON 配列に変換 ─────────────────────────────────────
IFS=',' read -r -a UPN_ARRAY <<< "$UPNS_CSV"
UPN_ARRAY=("${UPN_ARRAY[@]/#/}")  # no-op to keep array
# trim whitespace
for i in "${!UPN_ARRAY[@]}"; do
    UPN_ARRAY[$i]="$(echo -n "${UPN_ARRAY[$i]}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
done

UPNS_JSON=$(printf '%s\n' "${UPN_ARRAY[@]}" | jq -R . | jq -s .)

# ── Planner 担当者配列 ────────────────────────────────────────
if [[ -n "$PLANNER_ASSIGNEE_UPN" ]]; then
    ASSIGNEE_UPNS_JSON=$(jq -n --arg u "$PLANNER_ASSIGNEE_UPN" '[$u]')
else
    ASSIGNEE_UPNS_JSON="$UPNS_JSON"
fi

# ── サンプル脆弱性情報 ────────────────────────────────────────
CVE_ID="CVE-2026-12345"
COMPONENT="OpenSSL"
DUE_DATE=$(date -u -d "+7 days" +%Y-%m-%d 2>/dev/null || date -u -v+7d +%Y-%m-%d)

TITLE="${TITLE:-脆弱性通知: ${CVE_ID}}"
MESSAGE="${MESSAGE:-${COMPONENT} の重大脆弱性を検知しました。修正期限: ${DUE_DATE}}"

# ── ペイロード構築 ────────────────────────────────────────────
PAYLOAD=$(jq -n \
    --argjson upns "$UPNS_JSON" \
    --arg chat_id "$CHAT_ID" \
    --arg title "$TITLE" \
    --arg message "$MESSAGE" \
    --argjson planner_enabled "$([[ "$CREATE_PLANNER_TASK" == "true" ]] && echo true || echo false)" \
    --arg plan_id "$PLANNER_PLAN_ID" \
    --arg bucket_id "$PLANNER_BUCKET_ID" \
    --arg assignee_upn "$PLANNER_ASSIGNEE_UPN" \
    --argjson assignee_upns "$ASSIGNEE_UPNS_JSON" \
    --arg cve_id "$CVE_ID" \
    --arg severity "High" \
    --arg cvss "9.1" \
    --arg component "$COMPONENT" \
    --arg affected_version "3.0.0 - 3.0.13" \
    --arg fixed_version "3.0.14" \
    --arg service "payments-api" \
    --arg environment "production" \
    --arg due_date "$DUE_DATE" \
    --arg reference "https://nvd.nist.gov/vuln/detail/CVE-2026-12345" \
    --argjson target_user_count "${#UPN_ARRAY[@]}" \
    '{
        upns: $upns,
        chat_id: $chat_id,
        title: $title,
        message: $message,
        planner: {
            enabled: $planner_enabled,
            plan_id: $plan_id,
            bucket_id: $bucket_id,
            assignee_upn: $assignee_upn,
            assignee_upns: $assignee_upns
        },
        facts: {
            source: "test-vuln-notify.sh",
            targetUserCount: $target_user_count,
            cve_id: $cve_id,
            severity: $severity,
            cvss: $cvss,
            component: $component,
            affected_version: $affected_version,
            fixed_version: $fixed_version,
            service: $service,
            environment: $environment,
            due_date: $due_date,
            reference: $reference
        }
    }')

# ── リクエスト概要 ────────────────────────────────────────────
echo ""
echo "================================================"
echo "  脆弱性通知システム - 動作確認"
echo "================================================"
echo "  送信先  : $FUNCTION_URL"
echo "  UPN数   : ${#UPN_ARRAY[@]}"
echo "  chat_id : ${CHAT_ID:-(新規作成)}"
if [[ "$CREATE_PLANNER_TASK" == "true" ]]; then
    echo "  Planner : 有効"
    echo "  PlanId  : $PLANNER_PLAN_ID"
    echo "  BucketId: $PLANNER_BUCKET_ID"
else
    echo "  Planner : 無効"
fi
echo "------------------------------------------------"

# ── リクエスト送信 ────────────────────────────────────────────
HTTP_RESPONSE=$(mktemp)
trap 'rm -f "$HTTP_RESPONSE"' EXIT

HTTP_STATUS=$(curl -sS -o "$HTTP_RESPONSE" -w "%{http_code}" \
    -X POST "$FUNCTION_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_ACCESS_TOKEN}" \
    -d "$PAYLOAD")

BODY=$(cat "$HTTP_RESPONSE")

echo ""
if [[ "$HTTP_STATUS" =~ ^2[0-9]{2}$ ]]; then
    echo "[OK] 通知送信成功 (HTTP ${HTTP_STATUS})"
    if echo "$BODY" | jq -e . >/dev/null 2>&1; then
        echo "  レスポンス: $(echo "$BODY" | jq -c .)"
    else
        echo "  レスポンス: $BODY"
    fi
    echo ""
    exit 0
fi

echo "[ERROR] 送信失敗 (HTTP ${HTTP_STATUS})" >&2
if echo "$BODY" | jq -e . >/dev/null 2>&1; then
    echo "  詳細: $(echo "$BODY" | jq -c .)" >&2
else
    echo "  詳細: $BODY" >&2
fi
echo ""
exit 1
