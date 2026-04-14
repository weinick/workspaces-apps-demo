#!/bin/bash
# fleet-stack-deploy.sh
# 创建 Fleet、Stack 和 Auto Scaling 策略（一次性基础设施部署）
# 前置条件: cfn-workspaces-apps-demo.yaml 已部署完成，自定义镜像已制作完成
# URL 生成请使用 generate-urls.sh
# 扩缩容管理请使用 scale-fleet.sh
#
# 支持多 Fleet 场景：同一套 CFN 基础设施可部署多个 Fleet
# 只需用不同的 fleet-suffix 区分即可，如:
#   bash fleet-stack-deploy.sh ap-southeast-1 my-demo standard-image  standard  2 20 stream.standard.xlarge  ON_DEMAND
#   bash fleet-stack-deploy.sh ap-southeast-1 my-demo gpu-image       gpu       2 20 stream.graphics.g4dn.xlarge ON_DEMAND

set -euo pipefail

REGION="${1:-ap-southeast-1}"
CFN_STACK_NAME="${2:-my-demo}"      # CFN Stack 名称（读取网络配置用）
CUSTOM_IMAGE_NAME="${3:-}"          # 必须提供：自定义镜像名称
FLEET_SUFFIX="${4:-}"               # 必须提供：Fleet 标识后缀，如 standard / gpu / training
MIN_CAPACITY="${5:-2}"              # Fleet 最小实例数
MAX_CAPACITY="${6:-20}"             # Fleet 最大实例数（Auto Scaling 上限）
FLEET_INSTANCE_TYPE="${7:-}"        # 必须提供：实例类型
FLEET_TYPE="${8:-ON_DEMAND}"        # Fleet 类型（ON_DEMAND / ALWAYS_ON / ELASTIC）
MAX_SESSION_SECONDS="${9:-9000}"    # 会话最长时间（秒），默认 9000（2.5 小时）
DISCONNECT_SECONDS="${10:-900}"     # 断开连接后超时（秒），默认 900（15 分钟）
IDLE_SECONDS="${11:-900}"            # 空闲断开超时（秒），默认 900（15 分钟）

# ============================================================
# 帮助信息
# ============================================================
usage() {
  echo "Usage: $0 <region> <cfn-stack-name> <image-name> <fleet-suffix> [min] [max] <instance-type> [fleet-type] [max-session] [disconnect-timeout] [idle-timeout]"
  echo ""
  echo "必填参数:"
  echo "  region          AWS 区域 (如 ap-southeast-1)"
  echo "  cfn-stack-name  CloudFormation Stack 名称（提供网络配置）"
  echo "  image-name      自定义镜像名称（镜像制作完成后的名称）"
  echo "  fleet-suffix    Fleet 标识后缀，用于区分多个 Fleet（如 standard / gpu / training）"
  echo "  instance-type   实例类型（见下方参考）"
  echo ""
  echo "可选参数:"
  echo "  min                  最小实例数，默认 2"
  echo "  max                  最大实例数（Auto Scaling 上限），默认 20"
  echo "  fleet-type           Fleet 类型，默认 ON_DEMAND"
  echo "  max-session          会话最长时间（秒），默认 9000（2.5h），范围 600-432000"
  echo "  disconnect-timeout   断开连接后保持实例超时（秒），默认 900（15min），范围 60-432000"
  echo "  idle-timeout         空闲自动断开超时（秒），默认 900（15min），范围 60-3600（0=不断开）"
  echo ""
  echo "Fleet 类型说明:"
  echo "  ON_DEMAND   按需启动，有用户时才计全价，无用户时收极小的 stopped 费用。"
  echo "              用户连接时等待 1-2 分钟实例启动。"
  echo "              适合: 培训、演示、非实时性场景。"
  echo ""
  echo "  ALWAYS_ON   实例持续运行，用户连接即时无等待，但无论是否有用户均按全价计费。"
  echo "              适合: 企业生产环境、要求零等待的 SaaS 应用。"
  echo ""
  echo "  ELASTIC     由 AWS 全托管扩缩容，仅在 streaming 会话期间计费（按秒，最低 15 分钟）。"
  echo "              需要使用 App Block 打包应用（非镜像方式），启动时需下载挂载，延迟较高。"
  echo "              适合: 低频使用、对启动速度不敏感的轻量应用。"
  echo ""
  echo "实例类型参考:"
  echo "  通用:     stream.standard.medium / large / xlarge / 2xlarge"
  echo "  计算优化: stream.compute.large / xlarge / 2xlarge / 4xlarge / 8xlarge"
  echo "  内存优化: stream.memory.large / xlarge / 2xlarge / 4xlarge / 8xlarge"
  echo "  GPU G4dn: stream.graphics.g4dn.xlarge / 2xlarge / 4xlarge  (NVIDIA T4)"
  echo "  GPU G5:   stream.graphics.g5.xlarge / 2xlarge / 4xlarge    (NVIDIA A10G)"
  echo "  GPU G6:   stream.graphics.g6.xlarge / 2xlarge / 4xlarge    (NVIDIA L4)"
  echo ""
  echo "多 Fleet 示例:"
  echo "  # 非 GPU Fleet（通用软件）"
  echo "  $0 ap-southeast-1 my-demo my-standard-image-v1 standard 2 20 stream.standard.xlarge ON_DEMAND"
  echo ""
  echo "  # GPU Fleet（AI/图形软件）"
  echo "  $0 ap-southeast-1 my-demo my-gpu-image-v1 gpu 2 20 stream.graphics.g4dn.xlarge ON_DEMAND"
  exit 1
}

if [[ -z "$CUSTOM_IMAGE_NAME" || -z "$FLEET_SUFFIX" || -z "$FLEET_INSTANCE_TYPE" ]]; then
  usage
fi

# 校验 Fleet 类型
if [[ "$FLEET_TYPE" != "ON_DEMAND" && "$FLEET_TYPE" != "ALWAYS_ON" && "$FLEET_TYPE" != "ELASTIC" ]]; then
  echo "❌ 无效的 fleet-type: '$FLEET_TYPE'，必须为 ON_DEMAND / ALWAYS_ON / ELASTIC"
  exit 1
fi

FLEET_NAME="${CFN_STACK_NAME}-${FLEET_SUFFIX}-fleet"
STACK_NAME="${CFN_STACK_NAME}-${FLEET_SUFFIX}-stack"

# ============================================================
# 读取 CFN 网络配置
# ============================================================
echo "=== 读取 CloudFormation 网络配置 ==="
PRIVATE_SUBNET=$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnet1Id`].OutputValue' \
  --output text)

FLEET_SG=$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`FleetSecurityGroupId`].OutputValue' \
  --output text)

echo "CFN Stack:    $CFN_STACK_NAME"
echo "Fleet:        $FLEET_NAME"
echo "Stack:        $STACK_NAME"
echo "Image:        $CUSTOM_IMAGE_NAME"
echo "实例类型:     $FLEET_INSTANCE_TYPE"
echo "Fleet 类型:   $FLEET_TYPE"
echo "容量:         Min=$MIN_CAPACITY, Max=$MAX_CAPACITY"
echo "会话最长:     ${MAX_SESSION_SECONDS}s ($((MAX_SESSION_SECONDS/3600))h$((MAX_SESSION_SECONDS%3600/60))m)"
echo "断开超时:     ${DISCONNECT_SECONDS}s ($((DISCONNECT_SECONDS/60))min)"
echo "空闲超时:     ${IDLE_SECONDS}s ($((IDLE_SECONDS/60))min)"
echo "Subnet:       $PRIVATE_SUBNET"
echo "SG:           $FLEET_SG"

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
    --fleet-type "$FLEET_TYPE" \
    --compute-capacity DesiredInstances="$MIN_CAPACITY" \
    --region "$REGION" \
    --vpc-config SubnetIds="$PRIVATE_SUBNET",SecurityGroupIds="$FLEET_SG" \
    --display-name "${CFN_STACK_NAME} ${FLEET_SUFFIX} Fleet (${FLEET_INSTANCE_TYPE})" \
    --description "WorkSpaces Applications Fleet - ${CFN_STACK_NAME}/${FLEET_SUFFIX}" \
    --stream-view DESKTOP \
    --max-user-duration-in-seconds "$MAX_SESSION_SECONDS" \
    --disconnect-timeout-in-seconds "$DISCONNECT_SECONDS" \
    --idle-disconnect-timeout-in-seconds "$IDLE_SECONDS" \
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
# 2. 配置 Auto Scaling（ELASTIC 不支持 Auto Scaling）
# ============================================================
echo ""
echo "=== [2/5] 配置 Auto Scaling ==="

if [[ "$FLEET_TYPE" == "ELASTIC" ]]; then
  echo "ℹ️  ELASTIC fleet 由 AWS 全托管扩缩容，跳过 Auto Scaling 配置"
else
  aws application-autoscaling register-scalable-target \
    --service-namespace appstream \
    --resource-id "fleet/$FLEET_NAME" \
    --scalable-dimension appstream:fleet:DesiredCapacity \
    --min-capacity "$MIN_CAPACITY" \
    --max-capacity "$MAX_CAPACITY" \
    --region "$REGION"

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
  echo "Auto Scaling 配置 ✅ (Min: $MIN_CAPACITY, Max: $MAX_CAPACITY, 目标利用率: 75%)"
fi

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
    --display-name "${CFN_STACK_NAME} ${FLEET_SUFFIX} Stack" \
    --description "WorkSpaces Applications Stack - ${CFN_STACK_NAME}/${FLEET_SUFFIX}" \
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
echo "✅ Fleet 部署完成！"
echo "=============================="
echo "Fleet:        $FLEET_NAME (RUNNING)"
echo "Stack:        $STACK_NAME"
echo "实例类型:     $FLEET_INSTANCE_TYPE"
echo "Fleet 类型:   $FLEET_TYPE"
echo "Auto Scaling: Min=$MIN_CAPACITY, Max=$MAX_CAPACITY"
echo "会话最大时长: ${MAX_SESSION_SECONDS}s ($((MAX_SESSION_SECONDS/3600))h$((MAX_SESSION_SECONDS%3600/60))m)"
echo ""
echo "下一步 - 预热实例（培训前执行）："
echo "  bash scale-fleet.sh warmup <count> （ENV_NAME=${CFN_STACK_NAME}-${FLEET_SUFFIX}）"
echo "  ENV_NAME=${CFN_STACK_NAME}-${FLEET_SUFFIX} bash scale-fleet.sh warmup $MIN_CAPACITY"
echo ""
echo "下一步 - 生成 Streaming URL："
echo "  bash generate-urls.sh $REGION ${CFN_STACK_NAME}-${FLEET_SUFFIX} <人数> <有效期小时>"
