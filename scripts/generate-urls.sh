#!/bin/bash
# generate-urls.sh
# 为每次培训批量生成 Streaming URL，同时输出 TXT 和 CSV 文件
# 前置条件: fleet-stack-deploy.sh 已执行完成，Fleet 处于 RUNNING 状态

set -euo pipefail

REGION="${1:-ap-southeast-1}"
ENV_NAME="${2:-my-demo}"
STUDENT_COUNT="${3:-}"   # 必须提供
URL_HOURS="${4:-2.5}"    # URL 有效期（小时，支持小数）

if [[ -z "$STUDENT_COUNT" ]]; then
  echo "Usage: $0 <region> <env-name> <student-count> [url-validity-hours]"
  echo "Example: $0 ap-southeast-1 my-demo-gpu 20 3"
  echo ""
  echo "Parameters:"
  echo "  student-count       学员人数，生成对应数量的独立 URL"
  echo "  url-validity-hours  URL 有效期（小时，支持小数如 2.5）  (default: 2.5)"
  echo ""
  echo "输出文件:"
  echo "  <env-name>-urls-<timestamp>.csv  CSV 格式（含编号/UserID/URL，可直接用 Excel 打开）"
  echo "  <env-name>-urls-<timestamp>.txt  纯文本格式（备用）"
  exit 1
fi

FLEET_NAME="${ENV_NAME}-fleet"
STACK_NAME="${ENV_NAME}-stack"

# 小时转换为秒
URL_VALIDITY=$(python3 -c "print(int(float('${URL_HOURS}') * 3600))")
EXPIRE_TIME=$(python3 -c "
import datetime
expire = datetime.datetime.now() + datetime.timedelta(hours=float('${URL_HOURS}'))
print(expire.strftime('%Y-%m-%d %H:%M'))
")

# ============================================================
# 检查 Fleet 状态
# ============================================================
echo "=== 检查 Fleet 状态 ==="
FLEET_STATE=$(aws appstream describe-fleets \
  --names "$FLEET_NAME" --region "$REGION" \
  --query 'Fleets[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$FLEET_STATE" == "NOT_FOUND" || "$FLEET_STATE" == "None" ]]; then
  echo "❌ Fleet '$FLEET_NAME' 不存在，请先执行 fleet-stack-deploy.sh"
  exit 1
fi

if [[ "$FLEET_STATE" != "RUNNING" ]]; then
  echo "❌ Fleet 状态为 ${FLEET_STATE}（需要 RUNNING），请检查 Fleet 是否正常"
  exit 1
fi

FLEET_INFO=$(aws appstream describe-fleets \
  --names "$FLEET_NAME" --region "$REGION" \
  --query 'Fleets[0].ComputeCapacityStatus' --output json)

AVAILABLE=$(echo "$FLEET_INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Available', 0))")
DESIRED=$(echo "$FLEET_INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Desired', 0))")

echo "Fleet RUNNING ✅ (Desired: $DESIRED, Available: $AVAILABLE)"

if [[ "$AVAILABLE" -lt "$STUDENT_COUNT" ]]; then
  echo ""
  echo "⚠️  警告: 当前可用实例数 ($AVAILABLE) 少于学员人数 ($STUDENT_COUNT)"
  echo "   建议先预热: ENV_NAME=${ENV_NAME} bash scripts/scale-fleet.sh warmup $STUDENT_COUNT"
  echo ""
fi

# ============================================================
# 批量生成 Streaming URL
# ============================================================
echo ""
echo "=== 批量生成 Streaming URL ==="
echo "学员人数: $STUDENT_COUNT | 有效期: ${URL_HOURS}h | 过期时间: ${EXPIRE_TIME}"
echo ""

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CSV_FILE="${ENV_NAME}-urls-${TIMESTAMP}.csv"
TXT_FILE="${ENV_NAME}-urls-${TIMESTAMP}.txt"

# CSV 文件头
echo "编号,UserID,StreamingURL,有效期至" > "$CSV_FILE"

# TXT 文件头
{
  echo "# WorkSpaces Applications - Streaming URLs"
  echo "# 生成时间: $(date)"
  echo "# 有效期: ${URL_HOURS} 小时（过期时间: ${EXPIRE_TIME}）"
  echo "# 学员人数: ${STUDENT_COUNT}"
  echo "# Fleet: ${FLEET_NAME} | Stack: ${STACK_NAME}"
  echo ""
} > "$TXT_FILE"

for i in $(seq 1 "$STUDENT_COUNT"); do
  USER_ID="student-$(printf '%02d' $i)"
  URL=$(aws appstream create-streaming-url \
    --stack-name "$STACK_NAME" \
    --fleet-name "$FLEET_NAME" \
    --user-id "$USER_ID" \
    --region "$REGION" \
    --validity "$URL_VALIDITY" \
    --query 'StreamingURL' \
    --output text)

  # 写入 CSV（URL 含逗号，用双引号包裹）
  echo "${i},${USER_ID},\"${URL}\",${EXPIRE_TIME}" >> "$CSV_FILE"

  # 写入 TXT
  echo "${USER_ID}: ${URL}" >> "$TXT_FILE"

  echo "  $USER_ID ✅"
done

echo ""
echo "=============================="
echo "✅ URL 生成完成！"
echo "=============================="
echo "CSV 文件:  $CSV_FILE  （推荐，可用 Excel 打开，按列分发）"
echo "TXT 文件:  $TXT_FILE  （纯文本备用）"
echo "学员人数:  $STUDENT_COUNT"
echo "有效期:    ${URL_HOURS}h（过期时间: ${EXPIRE_TIME}）"
echo ""
echo "分发说明:"
echo "  - CSV 格式：用 Excel 打开，A 列编号对应学员座位，C 列为链接，D 列为过期时间"
echo "  - 每人一条链接，互不干扰，同一链接不支持多人同时使用"
echo "  - 链接过期后重新执行本脚本生成新 URL"
echo "  - 培训结束后执行: ENV_NAME=${ENV_NAME} bash scripts/scale-fleet.sh down"
