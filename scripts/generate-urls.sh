#!/bin/bash
# generate-urls.sh
# 为每次培训批量生成 Streaming URL
# 前置条件: fleet-stack-deploy.sh 已执行完成，Fleet 处于 RUNNING 状态

set -euo pipefail

REGION="${1:-ap-southeast-1}"
ENV_NAME="${2:-siemens-demo}"
STUDENT_COUNT="${3:-}"   # 必须提供
URL_HOURS="${4:-2.5}"    # URL 有效期（小时，支持小数）

if [[ -z "$STUDENT_COUNT" ]]; then
  echo "Usage: $0 <region> <env-name> <student-count> [url-validity-hours]"
  echo "Example: $0 ap-southeast-1 siemens-demo 20 3"
  echo ""
  echo "Parameters:"
  echo "  student-count       学员人数，生成对应数量的独立 URL"
  echo "  url-validity-hours  URL 有效期（小时，支持小数如 2.5）  (default: 2.5)"
  exit 1
fi

FLEET_NAME="${ENV_NAME}-fleet"
STACK_NAME="${ENV_NAME}-stack"

# 小时转换为秒
URL_VALIDITY=$(python3 -c "print(int(float('${URL_HOURS}') * 3600))")

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
  echo "❌ Fleet 状态为 $FLEET_STATE（需要 RUNNING），请检查 Fleet 是否正常"
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
  echo "   Auto Scaling 会自动扩容，但学员可能需要等待 3-5 分钟实例启动"
  echo "   建议提前扩容: aws appstream update-fleet --name $FLEET_NAME --compute-capacity DesiredInstances=$STUDENT_COUNT --region $REGION"
  echo ""
fi

# ============================================================
# 批量生成 Streaming URL
# ============================================================
echo ""
echo "=== 批量生成 Streaming URL ==="
echo "学员人数: $STUDENT_COUNT | 有效期: ${URL_HOURS}h (${URL_VALIDITY}s)"
echo ""

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
URL_FILE="${ENV_NAME}-streaming-urls-${TIMESTAMP}.txt"

echo "# WorkSpaces Applications Demo - Streaming URLs" > "$URL_FILE"
echo "# 生成时间: $(date)" >> "$URL_FILE"
echo "# 有效期: ${URL_HOURS} 小时 (${URL_VALIDITY} 秒)" >> "$URL_FILE"
echo "# 学员人数: ${STUDENT_COUNT}" >> "$URL_FILE"
echo "# Fleet: ${FLEET_NAME} | Stack: ${STACK_NAME}" >> "$URL_FILE"
echo "" >> "$URL_FILE"

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
  echo "${USER_ID}: ${URL}" >> "$URL_FILE"
  echo "  $USER_ID ✅"
done

echo ""
echo "=============================="
echo "✅ URL 生成完成！"
echo "=============================="
echo "URL 文件:    $URL_FILE"
echo "学员人数:    $STUDENT_COUNT"
echo "有效期:      ${URL_HOURS}h（从现在起）"
echo ""
echo "使用说明:"
echo "  1. 将文件中的链接按编号分发给对应学员（每人一条，互不干扰）"
echo "  2. 同一链接同时只允许一个并发会话"
echo "  3. 链接过期后重新执行本脚本生成新 URL"
echo "  4. 培训结束后执行 cleanup.sh 释放资源"
