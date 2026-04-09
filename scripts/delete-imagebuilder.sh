#!/bin/bash
# delete-imagebuilder.sh
# 停止并删除 Image Builder，释放计费资源
# 镜像制作完成后应立即执行本脚本，避免产生不必要的费用
#
# 使用示例:
#   bash delete-imagebuilder.sh ap-southeast-1 my-demo          # 删除 CFN 主 Image Builder
#   bash delete-imagebuilder.sh ap-southeast-1 my-demo standard  # 删除额外的 standard Image Builder

set -euo pipefail

REGION="${1:-ap-southeast-1}"
CFN_STACK_NAME="${2:-my-demo}"
BUILDER_SUFFIX="${3:-}"   # 可选，不填则删除 CFN 主 Image Builder

# 确定 Image Builder 名称
if [[ -z "$BUILDER_SUFFIX" ]]; then
  BUILDER_NAME="${CFN_STACK_NAME}-builder"
else
  BUILDER_NAME="${CFN_STACK_NAME}-${BUILDER_SUFFIX}-builder"
fi

echo "=== 删除 Image Builder ==="
echo "Region:  $REGION"
echo "Builder: $BUILDER_NAME"
echo ""

# 检查 Image Builder 是否存在
STATE=$(aws appstream describe-image-builders \
  --names "$BUILDER_NAME" --region "$REGION" \
  --query 'ImageBuilders[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$STATE" == "NOT_FOUND" || "$STATE" == "None" ]]; then
  echo "Image Builder '$BUILDER_NAME' 不存在，无需操作"
  exit 0
fi

echo "当前状态: $STATE"

# 二次确认
read -r -p "⚠️  确认删除 Image Builder '$BUILDER_NAME'？删除后不可恢复。[y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "已取消"
  exit 0
fi

# 如果正在运行，先停止
if [[ "$STATE" == "RUNNING" || "$STATE" == "PENDING" || "$STATE" == "UPDATING" ]]; then
  echo "停止 Image Builder..."
  aws appstream stop-image-builder \
    --name "$BUILDER_NAME" \
    --region "$REGION" > /dev/null
  echo "等待停止..."
  while true; do
    STATE=$(aws appstream describe-image-builders \
      --names "$BUILDER_NAME" --region "$REGION" \
      --query 'ImageBuilders[0].State' --output text 2>/dev/null || echo "NOT_FOUND")
    echo "  状态: $STATE"
    [[ "$STATE" == "STOPPED" ]] && break
    [[ "$STATE" == "NOT_FOUND" ]] && echo "✅ 已删除" && exit 0
    sleep 15
  done
  echo "Image Builder 已停止 ✅"
fi

# 删除
echo "删除 Image Builder..."
aws appstream delete-image-builder \
  --name "$BUILDER_NAME" \
  --region "$REGION" > /dev/null

echo ""
echo "✅ Image Builder '$BUILDER_NAME' 已删除，计费已停止"
