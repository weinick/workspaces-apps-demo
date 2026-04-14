#!/bin/bash
# cleanup.sh
# 一键清理 WorkSpaces Applications Demo 所有 AWS 资源
# 顺序: Fleet → Stack → 自定义镜像 → Image Builder → CloudFormation Stack
#
# 用法 1（位置参数）:
#   bash cleanup.sh <region> <cfn-stack-name> <fleet-suffix> [custom-image-name]
#
# 用法 2（环境变量，与 scale-fleet.sh 保持一致）:
#   ENV_NAME=my-demo-gpu bash cleanup.sh
#   REGION=us-east-1 ENV_NAME=my-demo-gpu bash cleanup.sh
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

REGION="${1:-${REGION:-ap-southeast-1}}"

# 支持两种参数模式：
# 1) 位置参数: cleanup.sh <region> <cfn-stack-name> <fleet-suffix> [image]
# 2) 环境变量: ENV_NAME=<cfn-stack-name>-<fleet-suffix> cleanup.sh
if [[ -n "${2:-}" && -n "${3:-}" ]]; then
  # 位置参数模式
  CFN_STACK_NAME="$2"
  FLEET_SUFFIX="$3"
  CUSTOM_IMAGE_NAME="${4:-}"
elif [[ -n "${ENV_NAME:-}" ]]; then
  # 环境变量模式：从 Fleet 描述和 tag 中自动获取镜像名和 CFN Stack 名称
  FLEET_NAME="${ENV_NAME}-fleet"
  CUSTOM_IMAGE_NAME=$(aws appstream describe-fleets \
    --names "$FLEET_NAME" --region "$REGION" \
    --query 'Fleets[0].ImageName' --output text 2>/dev/null || echo "")
  [[ "$CUSTOM_IMAGE_NAME" == "None" ]] && CUSTOM_IMAGE_NAME=""

  # 从 Fleet tag 读取 CFN Stack 名称
  FLEET_ARN=$(aws appstream describe-fleets \
    --names "$FLEET_NAME" --region "$REGION" \
    --query 'Fleets[0].Arn' --output text 2>/dev/null || echo "")
  if [[ -n "$FLEET_ARN" && "$FLEET_ARN" != "None" ]]; then
    CFN_STACK_NAME=$(aws appstream list-tags-for-resource \
      --resource-arn "$FLEET_ARN" --region "$REGION" \
      --query 'Tags.CfnStackName' --output text 2>/dev/null || echo "")
    [[ "$CFN_STACK_NAME" == "None" ]] && CFN_STACK_NAME=""
  fi
else
  echo "Usage:"
  echo "  $0 <region> <cfn-stack-name> <fleet-suffix> [custom-image-name]"
  echo "  ENV_NAME=<name> $0"
  echo ""
  echo "Examples:"
  echo "  $0 ap-southeast-1 my-demo gpu my-gpu-image-v1"
  echo "  ENV_NAME=my-demo-gpu $0"
  exit 1
fi

# 如果通过位置参数模式，拼接 Fleet/Stack 名称
FLEET_NAME="${FLEET_NAME:-${CFN_STACK_NAME}-${FLEET_SUFFIX}-fleet}"
STACK_NAME="${ENV_NAME:-${CFN_STACK_NAME}-${FLEET_SUFFIX}}-stack"

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
  echo "Fleet 状态: ${FLEET_STATE}，跳过停止步骤"
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

# ---- 6. 询问是否删除 CFN Stack ----
echo ""
read -r -p "是否同时删除 CloudFormation Stack（VPC、S3、IAM 等全部基础设施）？(y/N) " DEL_CFN
if [[ "$DEL_CFN" == "y" || "$DEL_CFN" == "Y" ]]; then
  # 环境变量模式下可能没有 CFN_STACK_NAME，需要询问
  if [[ -z "${CFN_STACK_NAME:-}" ]]; then
    read -r -p "请输入 CloudFormation Stack 名称: " CFN_STACK_NAME
    if [[ -z "$CFN_STACK_NAME" ]]; then
      echo "未提供 Stack 名称，跳过 CFN 删除"
      exit 0
    fi
  fi
  # 清空 S3 Bucket（CFN 删除前必须清空）
  echo ""
  echo "=== 清空 S3 Bucket ==="
  BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$CFN_STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstallerBucketName`].OutputValue' \
    --output text 2>/dev/null || true)
  if [[ -n "$BUCKET" && "$BUCKET" != "None" ]]; then
    echo "  清空 s3://$BUCKET ..."
    aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" > /dev/null 2>&1 || true
    echo "  ✅ Bucket 已清空"
  fi

  # 删除 CFN Stack
  echo ""
  echo "=== 删除 CloudFormation Stack ==="
  aws cloudformation delete-stack --stack-name "$CFN_STACK_NAME" --region "$REGION"
  echo "  等待 Stack 删除完成（约 5-10 分钟）..."
  aws cloudformation wait stack-delete-complete --stack-name "$CFN_STACK_NAME" --region "$REGION" 2>/dev/null
  echo "  ✅ CloudFormation Stack '$CFN_STACK_NAME' 已删除"
  echo ""
  echo "=============================="
  echo "✅ 所有资源已清理完毕"
  echo "=============================="
else
  echo ""
  if [[ -n "${CFN_STACK_NAME:-}" ]]; then
    echo "如需后续删除全部基础设施："
    echo "  aws cloudformation delete-stack --stack-name $CFN_STACK_NAME --region $REGION"
  else
    echo "如需后续删除全部基础设施："
    echo "  aws cloudformation delete-stack --stack-name <cfn-stack-name> --region $REGION"
  fi
fi
