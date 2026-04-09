#!/bin/bash
# cleanup.sh
# 一键清理 WorkSpaces Applications Demo 所有 AWS 资源
# 顺序: Fleet → Stack → 自定义镜像 → Image Builder → CloudFormation Stack
#
# 用法:
#   bash cleanup.sh <region> <env-name> <fleet-suffix> [custom-image-name]
#
# 示例（单 Fleet）:
#   bash cleanup.sh ap-southeast-1 my-demo gpu my-gpu-image-v1
#
# 示例（多 Fleet，多次执行）:
#   bash cleanup.sh ap-southeast-1 my-demo standard my-standard-image-v1
#   bash cleanup.sh ap-southeast-1 my-demo gpu      my-gpu-image-v1
#
# 清理完所有 Fleet 后，最后删除 CFN 基础设施：
#   aws cloudformation delete-stack --stack-name my-demo --region ap-southeast-1

set -euo pipefail

REGION="${1:-ap-southeast-1}"
CFN_STACK_NAME="${2:-my-demo}"
FLEET_SUFFIX="${3:-}"
CUSTOM_IMAGE_NAME="${4:-}"

if [[ -z "$FLEET_SUFFIX" ]]; then
  echo "Usage: $0 <region> <cfn-stack-name> <fleet-suffix> [custom-image-name]"
  echo "Example: $0 ap-southeast-1 my-demo gpu my-gpu-image-v1"
  exit 1
fi

FLEET_NAME="${CFN_STACK_NAME}-${FLEET_SUFFIX}-fleet"
STACK_NAME="${CFN_STACK_NAME}-${FLEET_SUFFIX}-stack"

echo "=============================="
echo "WorkSpaces Applications Cleanup"
echo "=============================="
echo ""
echo "Region:   $REGION"
echo "Fleet:    $FLEET_NAME"
echo "Stack:    $STACK_NAME"
[[ -n "$CUSTOM_IMAGE_NAME" ]] && echo "Image:    $CUSTOM_IMAGE_NAME"
echo ""
read -r -p "⚠️  确认删除以上资源？(y/N) " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "已取消"
  exit 0
fi
echo ""

# ---- 1. 停止 Fleet ----
echo "=== [1/5] 停止 Fleet ==="
FLEET_STATE=$(aws appstream describe-fleets \
  --names "$FLEET_NAME" --region "$REGION" \
  --query 'Fleets[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$FLEET_STATE" == "NOT_FOUND" || "$FLEET_STATE" == "None" ]]; then
  echo "Fleet 不存在，跳过"
elif [[ "$FLEET_STATE" == "RUNNING" ]]; then
  aws appstream stop-fleet --name "$FLEET_NAME" --region "$REGION"
  echo "等待 Fleet 停止..."
  aws appstream wait fleet-stopped --names "$FLEET_NAME" --region "$REGION"
  echo "Fleet 已停止 ✅"
else
  echo "Fleet 状态: $FLEET_STATE，跳过停止步骤"
fi

# ---- 2. 解除 Fleet 与 Stack 的关联 ----
echo ""
echo "=== [2/5] 解除 Fleet-Stack 关联 ==="
aws appstream disassociate-fleet \
  --fleet-name "$FLEET_NAME" \
  --stack-name "$STACK_NAME" \
  --region "$REGION" 2>/dev/null && echo "关联已解除 ✅" || echo "无关联，跳过"

# ---- 3. 删除 Stack ----
echo ""
echo "=== [3/5] 删除 Stack ==="
aws appstream delete-stack \
  --name "$STACK_NAME" \
  --region "$REGION" 2>/dev/null && echo "Stack 删除成功 ✅" || echo "Stack 不存在，跳过"

# ---- 4. 删除 Fleet ----
echo ""
echo "=== [4/5] 删除 Fleet ==="
aws appstream delete-fleet \
  --name "$FLEET_NAME" \
  --region "$REGION" 2>/dev/null && echo "Fleet 删除成功 ✅" || echo "Fleet 不存在，跳过"

# ---- 5. 删除自定义镜像 ----
echo ""
echo "=== [5/5] 删除自定义镜像 ==="
if [[ -z "$CUSTOM_IMAGE_NAME" ]]; then
  echo "未提供镜像名称，跳过"
else
  IMAGE_STATE=$(aws appstream describe-images \
    --names "$CUSTOM_IMAGE_NAME" --region "$REGION" \
    --query 'Images[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$IMAGE_STATE" == "NOT_FOUND" || "$IMAGE_STATE" == "None" ]]; then
    echo "镜像不存在，跳过"
  else
    aws appstream delete-image \
      --name "$CUSTOM_IMAGE_NAME" \
      --region "$REGION" && echo "镜像删除成功 ✅" || echo "镜像删除失败（可能仍有 Fleet 依赖）"
  fi
fi

echo ""
echo "=============================="
echo "✅ Fleet 资源清理完成"
echo "=============================="
echo ""
echo "如需删除 Image Builder（如不再制作镜像）："
echo "  bash scripts/delete-imagebuilder.sh $REGION $CFN_STACK_NAME"
echo ""
echo "如需删除全部基础设施（VPC、S3、IAM 等），请在所有 Fleet 清理完后执行："
echo "  aws cloudformation delete-stack --stack-name $CFN_STACK_NAME --region $REGION"
