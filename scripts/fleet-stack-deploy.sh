#!/bin/bash
# fleet-stack-deploy.sh
# 创建 Fleet、Stack 和 Auto Scaling 策略（一次性基础设施部署）
# 前置条件: cfn-workspaces-apps-demo.yaml 已部署完成
# URL 生成请使用 generate-urls.sh

set -euo pipefail

REGION="${1:-ap-southeast-1}"
ENV_NAME="${2:-siemens-demo}"
CUSTOM_IMAGE_NAME="${3:-}"   # 必须提供
MIN_CAPACITY="${4:-2}"       # Fleet 最小实例数（热备数量）
MAX_CAPACITY="${5:-10}"      # Fleet 最大实例数（Auto Scaling 上限）
# 参数6: 实例类型（可选，不传则从 CFN stack 参数自动读取）
INSTANCE_TYPE_OVERRIDE="${6:-}"

if [[ -z "$CUSTOM_IMAGE_NAME" ]]; then
  echo "Usage: $0 <region> <env-name> <custom-image-name> [min-capacity] [max-capacity] [instance-type]"
  echo "Example: $0 ap-southeast-1 my-demo my-custom-image-v1 2 20"
  echo "Example: $0 ap-southeast-1 my-demo my-custom-image-v1 2 20 stream.graphics.g5.xlarge"
  echo ""
  echo "Parameters:"
  echo "  min-capacity   最小实例数，培训前预热，建议设为最大同时在线用户数  (default: 2)"
  echo "  max-capacity   最大实例数，Auto Scaling 上限  (default: 10)"
  echo "  instance-type  实例类型，不填则自动读取 CFN 参数 FleetInstanceType"
  echo ""
  echo "实例类型参考:"
  echo "  通用:    stream.standard.medium / large / xlarge / 2xlarge"
  echo "  计算优化: stream.compute.large / xlarge / 2xlarge / 4xlarge"
  echo "  内存优化: stream.memory.large / xlarge / 2xlarge / 4xlarge"
  echo "  GPU G4dn: stream.graphics.g4dn.xlarge / 2xlarge / 4xlarge  (NVIDIA T4)"
  echo "  GPU G5:  stream.graphics.g5.xlarge / 2xlarge / 4xlarge     (NVIDIA A10G)"
  echo "  GPU G6:  stream.graphics.g6.xlarge / 2xlarge / 4xlarge     (NVIDIA L4)"
  exit 1
fi

FLEET_NAME="${ENV_NAME}-fleet"
STACK_NAME="${ENV_NAME}-stack"

# ============================================================
# 读取 CFN 配置
# ============================================================
echo "=== 读取 CloudFormation 配置 ==="
PRIVATE_SUBNET=$(aws cloudformation describe-stacks \
  --stack-name "$ENV_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnet1Id`].OutputValue' \
  --output text)

FLEET_SG=$(aws cloudformation describe-stacks \
  --stack-name "$ENV_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`FleetSecurityGroupId`].OutputValue' \
  --output text)

# 实例类型：优先用命令行参数，其次从 CFN Parameters 读取
if [[ -n "$INSTANCE_TYPE_OVERRIDE" ]]; then
  FLEET_INSTANCE_TYPE="$INSTANCE_TYPE_OVERRIDE"
  echo "实例类型: $FLEET_INSTANCE_TYPE (命令行指定)"
else
  FLEET_INSTANCE_TYPE=$(aws cloudformation describe-stacks \
    --stack-name "$ENV_NAME" --region "$REGION" \
    --query 'Stacks[0].Parameters[?ParameterKey==`FleetInstanceType`].ParameterValue' \
    --output text)
  if [[ -z "$FLEET_INSTANCE_TYPE" || "$FLEET_INSTANCE_TYPE" == "None" ]]; then
    echo "⚠️  CFN 中未找到 FleetInstanceType 参数，使用默认值 stream.graphics.g4dn.xlarge"
    FLEET_INSTANCE_TYPE="stream.graphics.g4dn.xlarge"
  else
    echo "实例类型: $FLEET_INSTANCE_TYPE (从 CFN 参数读取)"
  fi
fi

echo "Subnet: $PRIVATE_SUBNET | SG: $FLEET_SG"
echo "容量配置: Min=$MIN_CAPACITY, Max=$MAX_CAPACITY"

# ============================================================
# 1. 创建 Fleet
# ============================================================
echo ""
echo "=== [1/5] 创建 Fleet ==="

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
    --display-name "${ENV_NAME} Fleet (${FLEET_INSTANCE_TYPE})" \
    --description "WorkSpaces Applications Fleet - ${ENV_NAME}" \
    --stream-view DESKTOP \
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
echo "=== [2/5] 配置 Auto Scaling ==="

aws application-autoscaling register-scalable-target \
  --service-namespace appstream \
  --resource-id "fleet/$FLEET_NAME" \
  --scalable-dimension appstream:fleet:DesiredCapacity \
  --min-capacity "$MIN_CAPACITY" \
  --max-capacity "$MAX_CAPACITY" \
  --region "$REGION"
echo "Scalable target 注册 ✅ (Min: $MIN_CAPACITY, Max: $MAX_CAPACITY)"

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
echo "=== [3/5] 创建 Stack ==="

STACK_EXISTS=$(aws appstream describe-stacks \
  --names "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Name' --output text 2>/dev/null || echo "")

if [[ -z "$STACK_EXISTS" || "$STACK_EXISTS" == "None" ]]; then
  aws appstream create-stack \
    --name "$STACK_NAME" \
    --display-name "${ENV_NAME} Stack" \
    --description "WorkSpaces Applications Stack - ${ENV_NAME}" \
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
echo "=== [4/5] 关联 Fleet 和 Stack ==="
aws appstream associate-fleet \
  --fleet-name "$FLEET_NAME" \
  --stack-name "$STACK_NAME" \
  --region "$REGION" 2>/dev/null && echo "关联成功 ✅" || echo "已关联，跳过"

# ============================================================
# 5. 输出汇总
# ============================================================
echo ""
echo "=== [5/5] 部署汇总 ==="
echo ""
echo "=============================="
echo "✅ 基础设施部署完成！"
echo "=============================="
echo "Fleet:         $FLEET_NAME (RUNNING)"
echo "Stack:         $STACK_NAME"
echo "实例类型:       $FLEET_INSTANCE_TYPE"
echo "Auto Scaling:  Min=$MIN_CAPACITY, Max=$MAX_CAPACITY"
echo "会话最大时长:   2.5 小时"
echo ""
echo "下一步 - 生成学员 Streaming URL："
echo "  bash generate-urls.sh $REGION $ENV_NAME <学员人数> <有效期小时>"
echo "  示例: bash generate-urls.sh $REGION $ENV_NAME 20 3"
