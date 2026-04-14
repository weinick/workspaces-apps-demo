#!/bin/bash
# scale-fleet.sh
# Fleet 扩缩容管理 — 培训预热、会间缩容、培训结束归零
#
# 用法:
#   bash scale-fleet.sh <action> [options]
#
# Actions:
#   warmup  <count>  预热：将实例扩容至指定数量，等待全部就绪
#   scale   <count>  调整：直接设置 DesiredInstances（不等待）
#   down             归零：培训结束后将容量设为 0，停止计费
#   status           查看：当前 Fleet 容量和状态
#
# 示例:
#   bash scale-fleet.sh warmup 90          # 第一场前预热 90 个实例
#   bash scale-fleet.sh warmup 42          # 第二场前缩至 42 并等待就绪
#   bash scale-fleet.sh down               # 培训结束归零
#   bash scale-fleet.sh status             # 查看当前状态
#
# 环境变量（可选，覆盖默认值）:
#   REGION    AWS 区域  (default: ap-southeast-1)
#   ENV_NAME  环境名称  (default: siemens-demo)

set -euo pipefail

ACTION="${1:-}"
REGION="${REGION:-ap-southeast-1}"
ENV_NAME="${ENV_NAME:-siemens-demo}"
FLEET_NAME="${ENV_NAME}-fleet"

# ============================================================
# 帮助信息
# ============================================================
usage() {
  echo "Usage: $0 <action> [count]"
  echo ""
  echo "Actions:"
  echo "  warmup <count>   预热至指定数量，等待所有实例 Available"
  echo "  scale  <count>   设置 DesiredInstances（不等待）"
  echo "  down             归零（DesiredInstances=0），停止计费"
  echo "  status           查看当前容量状态"
  echo ""
  echo "Environment variables:"
  echo "  REGION=$REGION"
  echo "  ENV_NAME=$ENV_NAME"
  echo ""
  echo "Examples:"
  echo "  bash scale-fleet.sh warmup 90"
  echo "  REGION=us-east-1 bash scale-fleet.sh warmup 42"
  echo "  bash scale-fleet.sh down"
  exit 1
}

if [[ -z "$ACTION" ]]; then
  usage
fi

# ============================================================
# 工具函数：获取 Fleet 状态
# ============================================================
get_fleet_status() {
  aws appstream describe-fleets --profile global \
    --names "$FLEET_NAME" --region "$REGION" \
    --query 'Fleets[0].ComputeCapacityStatus' \
    --output json 2>/dev/null || echo "{}"
}

print_status() {
  local info
  info=$(get_fleet_status)
  local state
  state=$(aws appstream describe-fleets --profile global \
    --names "$FLEET_NAME" --region "$REGION" \
    --query 'Fleets[0].State' --output text 2>/dev/null || echo "UNKNOWN")

  local desired running available in_use
  desired=$(echo "$info"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Desired', 0))")
  running=$(echo "$info"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Running', 0))")
  available=$(echo "$info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Available', 0))")
  in_use=$(echo "$info"    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('InUse', 0))")

  echo "Fleet:     $FLEET_NAME"
  echo "State:     $state"
  echo "Desired:   $desired"
  echo "Running:   $running"
  echo "Available: $available (空闲可分配)"
  echo "InUse:     $in_use    (用户占用中)"
}

# ============================================================
# 检查 Fleet 是否存在
# ============================================================
check_fleet_exists() {
  local name
  name=$(aws appstream describe-fleets --profile global \
    --names "$FLEET_NAME" --region "$REGION" \
    --query 'Fleets[0].Name' --output text 2>/dev/null || echo "")
  if [[ -z "$name" || "$name" == "None" ]]; then
    echo "❌ Fleet '$FLEET_NAME' 不存在，请先执行 fleet-stack-deploy.sh"
    exit 1
  fi
}

# ============================================================
# Action: status
# ============================================================
if [[ "$ACTION" == "status" ]]; then
  check_fleet_exists
  echo "=== Fleet 状态 ==="
  print_status
  exit 0
fi

# ============================================================
# Action: down
# ============================================================
if [[ "$ACTION" == "down" ]]; then
  check_fleet_exists
  echo "=== 归零 Fleet 容量 ==="
  echo "Fleet: $FLEET_NAME | Region: $REGION"
  echo ""

  # 检查是否有用户仍在使用
  INFO=$(get_fleet_status)
  IN_USE=$(echo "$INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('InUse', 0))")
  if [[ "$IN_USE" -gt 0 ]]; then
    echo "⚠️  警告: 当前有 $IN_USE 个会话仍在使用中"
    read -r -p "确认强制归零？在线用户将在当前会话结束后自动释放 [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "已取消"
      exit 0
    fi
  fi

  # 更新 Auto Scaling 边界
  aws application-autoscaling register-scalable-target --profile global \
    --service-namespace appstream \
    --resource-id "fleet/$FLEET_NAME" \
    --scalable-dimension appstream:fleet:DesiredCapacity \
    --min-capacity 0 \
    --max-capacity 0 \
    --region "$REGION" 2>/dev/null || true

  # 设置 DesiredInstances=0
  aws appstream update-fleet --profile global \
    --name "$FLEET_NAME" \
    --compute-capacity DesiredInstances=0 \
    --region "$REGION" > /dev/null

  echo "✅ 容量已设为 0，stopped instance 费用停止计费"
  echo "   （当前在线用户的会话将持续到会话超时或主动断开）"
  echo ""
  print_status
  exit 0
fi

# ============================================================
# Action: scale / warmup — 需要 count 参数
# ============================================================
COUNT="${2:-}"
if [[ -z "$COUNT" ]]; then
  echo "❌ '$ACTION' 需要提供实例数量"
  usage
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  echo "❌ 实例数量必须为正整数，收到: '$COUNT'"
  exit 1
fi

check_fleet_exists

# ============================================================
# Action: scale（直接设置，不等待）
# ============================================================
if [[ "$ACTION" == "scale" ]]; then
  echo "=== 调整 Fleet 容量 ==="
  echo "Fleet: $FLEET_NAME | Region: $REGION | DesiredInstances: $COUNT"

  # 同步更新 Auto Scaling 边界
  aws application-autoscaling register-scalable-target --profile global \
    --service-namespace appstream \
    --resource-id "fleet/$FLEET_NAME" \
    --scalable-dimension appstream:fleet:DesiredCapacity \
    --min-capacity "$COUNT" \
    --max-capacity "$COUNT" \
    --region "$REGION" 2>/dev/null || true

  aws appstream update-fleet --profile global \
    --name "$FLEET_NAME" \
    --compute-capacity DesiredInstances="$COUNT" \
    --region "$REGION" > /dev/null

  echo "✅ Desired 已设为 $COUNT（实例正在启动，无需等待）"
  echo ""
  print_status
  exit 0
fi

# ============================================================
# Action: warmup（设置容量并等待所有实例 Available）
# ============================================================
if [[ "$ACTION" == "warmup" ]]; then
  echo "=== 预热 Fleet ==="
  echo "Fleet:   $FLEET_NAME"
  echo "Region:  $REGION"
  echo "目标容量: $COUNT 个实例"
  echo ""

  # 更新 Auto Scaling 边界
  aws application-autoscaling register-scalable-target --profile global \
    --service-namespace appstream \
    --resource-id "fleet/$FLEET_NAME" \
    --scalable-dimension appstream:fleet:DesiredCapacity \
    --min-capacity "$COUNT" \
    --max-capacity "$COUNT" \
    --region "$REGION" 2>/dev/null || true

  # 设置目标容量
  aws appstream update-fleet --profile global \
    --name "$FLEET_NAME" \
    --compute-capacity DesiredInstances="$COUNT" \
    --region "$REGION" > /dev/null

  echo "Desired 已设为 $COUNT，等待实例就绪..."
  echo "（On-Demand 实例启动约需 1-2 分钟，大规模扩容请耐心等待）"
  echo ""

  # 等待循环：每 30 秒检查一次
  WAIT_START=$(date +%s)
  while true; do
    INFO=$(get_fleet_status)
    AVAILABLE=$(echo "$INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Available', 0))")
    DESIRED=$(echo "$INFO"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Desired', 0))")
    IN_USE=$(echo "$INFO"    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('InUse', 0))")
    READY=$((AVAILABLE + IN_USE))

    ELAPSED=$(( $(date +%s) - WAIT_START ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    ELAPSED_SEC=$(( ELAPSED % 60 ))

    echo "  [${ELAPSED_MIN}m${ELAPSED_SEC}s] 就绪: ${READY}/${DESIRED}  (Available: $AVAILABLE, InUse: $IN_USE)"

    if [[ "$READY" -ge "$COUNT" ]]; then
      break
    fi
    sleep 30
  done

  echo ""
  echo "=============================="
  echo "✅ 预热完成！$COUNT 个实例已就绪"
  echo "=============================="
  echo ""
  print_status
  echo ""
  echo "下一步 — 生成学员 Streaming URL："
  echo "  bash generate-urls.sh $REGION $ENV_NAME $COUNT <有效期小时>"
  exit 0
fi

# 未知 action
echo "❌ 未知 action: '$ACTION'"
usage
