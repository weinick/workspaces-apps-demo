#!/bin/bash
# fleet-stack-deploy.sh
# 在自定义镜像制作完成后，用此脚本创建 Fleet、Stack、Auto Scaling 策略，并批量生成 Streaming URL
# 前置条件: cfn-workspaces-apps-demo.yaml 已部署完成

set -euo pipefail

REGION="${1:-ap-southeast-1}"
ENV_NAME="${2:-siemens-demo}"
CUSTOM_IMAGE_NAME="${3:-}"   # 必须提供
STUDENT_COUNT="${4:-10}"     # 预期学员人数，用于 Auto Scaling 和批量生成 URL
URL_VALIDITY="${5:-9000}"    # Streaming URL 有效期（秒），默认 2.5 小时

if [[ -z "$CUSTOM_IMAGE_NAME" ]]; then
  echo "Usage: $0 <region> <env-name> <custom-image-name> [student-count] [url-validity-seconds]"
  echo "Example: $0 ap-southeast-1 siemens-demo siemens-demo-custom-image-v1 20 9000"
  exit 1
fi

FLEET_NAME="${ENV_NAME}-fleet"
STACK_NAME="${ENV_NAME}-stack"
FLEET_INSTANCE_TYPE="stream.graphics.g4dn.xlarge"

# Auto Scaling 参数：Min = 学员数，Max = 学员数 × 1.5（向上取整）
MIN_CAPACITY=$STUDENT_COUNT
MAX_CAPACITY=$(python3 -c "import math; print(max(${STUDENT_COUNT}, math.ceil(${STUDENT_COUNT} * 1.5)))")

# 从 CFN Outputs 获取 Subnet 和 SG
echo "=== 读取 CloudFormation 配置 ==="
PRIVATE_SUBNET=$(aws cloudformation describe-stacks \
  --stack-name "$ENV_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnet1Id`].OutputValue' \
  --output text)

FLEET_SG=$(aws cloudformation describe-stacks \
  --stack-name "$ENV_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`FleetSecurityGroupId`].OutputValue' \
  --output text)

echo "Subnet: $PRIVATE_SUBNET | SG: $FLEET_SG"
echo "学员人数: $STUDENT_COUNT | Min容量: $MIN_CAPACITY | Max容量: $MAX_CAPACITY"

# ============================================================
# 1. 创建 Fleet
# ============================================================
echo ""
echo "=== [1/6] 创建 Fleet ==="
echo "Fleet: $FLEET_NAME | Image: $CUSTOM_IMAGE_NAME | Instance: $FLEET_INSTANCE_TYPE"

FLEET_EXISTS=$(aws appstream describe-fleets \
  --names "$FLEET_NAME" --region "$REGION" \
  --query 'Fleets[0].Name' --output text 2>/dev/null || echo "")

if [[ -z "$FLEET_EXISTS" || "$FLEET_EXISTS" == "None" ]]; then
  aws appstream create-fleet \
    --name "$FLEET_NAME" \
    --image-name "$CUSTOM_IMAGE_NAME" \
    --instance-type "$FLEET_INSTANCE_TYPE" \
    --fleet-type "ON_DEMAND" \
    --compute-capacity DesiredInstances="$MIN_CAPACITY" \
    --region "$REGION" \
    --vpc-config SubnetIds="$PRIVATE_SUBNET",SecurityGroupIds="$FLEET_SG" \
    --display-name "Siemens Demo Fleet (G4DN)" \
    --description "Mendix Studio Pro + Altair AI Studio" \
    --stream-view APP \
    --max-user-duration-in-seconds 9000 \
    --disconnect-timeout-in-seconds 9000 \
    --idle-disconnect-timeout-in-seconds 9000 \
    --output json > /dev/null
  echo "Fleet 创建成功 ✅"
else
  echo "Fleet 已存在，跳过创建"
fi

echo "启动 Fleet 并等待 RUNNING..."
aws appstream start-fleet --name "$FLEET_NAME" --region "$REGION" 2>/dev/null || true
while true; do
  STATE=$(aws appstream describe-fleets \
    --names "$FLEET_NAME" --region "$REGION" \
    --query 'Fleets[0].State' --output text)
  echo "  Fleet 状态: $STATE"
  [[ "$STATE" == "RUNNING" ]] && break
  sleep 30
done
echo "Fleet RUNNING ✅"

# ============================================================
# 2. 配置 Auto Scaling
# ============================================================
echo ""
echo "=== [2/6] 配置 Auto Scaling ==="

aws application-autoscaling register-scalable-target \
  --service-namespace appstream \
  --resource-id "fleet/$FLEET_NAME" \
  --scalable-dimension appstream:fleet:DesiredCapacity \
  --min-capacity "$MIN_CAPACITY" \
  --max-capacity "$MAX_CAPACITY" \
  --region "$REGION"
echo "Scalable target 注册 ✅ (Min: $MIN_CAPACITY, Max: $MAX_CAPACITY)"

# 扩容策略：容量利用率超过 75% 时扩容
aws application-autoscaling put-scaling-policy \
  --policy-name "${FLEET_NAME}-scale-out" \
  --service-namespace appstream \
  --resource-id "fleet/$FLEET_NAME" \
  --scalable-dimension appstream:fleet:DesiredCapacity \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 75.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "AppStreamAverageCapacityUtilization"
    },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 300
  }' \
  --region "$REGION" > /dev/null
echo "Auto Scaling 策略配置 ✅ (目标利用率: 75%, 扩容冷却: 60s, 缩容冷却: 300s)"

# ============================================================
# 3. 创建 Stack
# ============================================================
echo ""
echo "=== [3/6] 创建 Stack ==="

STACK_EXISTS=$(aws appstream describe-stacks \
  --names "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Name' --output text 2>/dev/null || echo "")

if [[ -z "$STACK_EXISTS" || "$STACK_EXISTS" == "None" ]]; then
  aws appstream create-stack \
    --name "$STACK_NAME" \
    --display-name "Siemens Demo Stack" \
    --description "WorkSpaces Applications Demo - Mendix + Altair AI Studio" \
    --region "$REGION" \
    --user-settings \
      Action=CLIPBOARD_COPY_FROM_LOCAL_DEVICE,Permission=ENABLED \
      Action=CLIPBOARD_COPY_TO_LOCAL_DEVICE,Permission=ENABLED \
      Action=FILE_UPLOAD,Permission=ENABLED \
      Action=FILE_DOWNLOAD,Permission=ENABLED \
      Action=PRINTING_TO_LOCAL_DEVICE,Permission=DISABLED \
    --output json > /dev/null
  echo "Stack 创建成功 ✅"
else
  echo "Stack 已存在，跳过创建"
fi

# ============================================================
# 4. 关联 Fleet 和 Stack
# ============================================================
echo ""
echo "=== [4/6] 关联 Fleet 和 Stack ==="
aws appstream associate-fleet \
  --fleet-name "$FLEET_NAME" \
  --stack-name "$STACK_NAME" \
  --region "$REGION" 2>/dev/null && echo "关联成功 ✅" || echo "已关联，跳过"

# ============================================================
# 5. 批量生成 Streaming URL
# ============================================================
echo ""
echo "=== [5/6] 批量生成 Streaming URL (${STUDENT_COUNT} 个，有效期 ${URL_VALIDITY} 秒) ==="
echo ""

URL_FILE="${ENV_NAME}-streaming-urls-$(date +%Y%m%d-%H%M%S).txt"
echo "# WorkSpaces Applications Demo - Streaming URLs" > "$URL_FILE"
echo "# 生成时间: $(date)" >> "$URL_FILE"
echo "# 有效期: ${URL_VALIDITY} 秒 ($(( URL_VALIDITY / 3600 ))h$(( (URL_VALIDITY % 3600) / 60 ))m)" >> "$URL_FILE"
echo "# 学员人数: ${STUDENT_COUNT}" >> "$URL_FILE"
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
echo "URL 已保存到: $URL_FILE"

# ============================================================
# 6. 输出汇总
# ============================================================
echo ""
echo "=============================="
echo "✅ 部署完成！"
echo "=============================="
echo "Fleet:        $FLEET_NAME (RUNNING, Min: $MIN_CAPACITY, Max: $MAX_CAPACITY)"
echo "Stack:        $STACK_NAME"
echo "学员人数:      $STUDENT_COUNT"
echo "URL 有效期:    ${URL_VALIDITY}s ($(( URL_VALIDITY / 3600 ))h$(( (URL_VALIDITY % 3600) / 60 ))m)"
echo "URL 文件:      $URL_FILE"
echo ""
echo "使用说明:"
echo "  1. 将 $URL_FILE 中的链接分发给对应学员"
echo "  2. 每条链接对应一个独立桌面，互不干扰"
echo "  3. 同一链接同时只允许一个并发会话"
echo "  4. 培训结束后执行 cleanup.sh 释放资源"
echo ""
echo "重新生成 URL（URL 过期后）:"
echo "  bash $0 $REGION $ENV_NAME $CUSTOM_IMAGE_NAME $STUDENT_COUNT <新有效期秒数>"
