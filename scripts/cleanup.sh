#!/bin/bash
# cleanup.sh
# 一键清理 WorkSpaces Applications Demo 所有 AWS 资源
# 顺序: Fleet → Stack → 自定义镜像 → Image Builder → CloudFormation Stack

set -euo pipefail

REGION="${1:-ap-southeast-1}"
STACK_NAME="${2:-siemens-demo}"
CUSTOM_IMAGE_NAME="${3:-siemens-demo-custom-image-v1}"

FLEET_NAME="${STACK_NAME}-fleet"
STACK_AS_NAME="${STACK_NAME}-stack"

echo "=============================="
echo "WorkSpaces Applications Demo"
echo "Cleanup Script"
echo "=============================="
echo ""
echo "区域:   $REGION"
echo "Stack:  $STACK_NAME"
echo "镜像:   $CUSTOM_IMAGE_NAME"
echo ""
read -p "⚠️  确认删除以上所有资源？(y/N) " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "已取消"
  exit 0
fi
echo ""

# ---- 1. 停止 Fleet ----
echo "=== [1/6] 停止 Fleet ==="
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
echo "=== [2/6] 解除 Fleet-Stack 关联 ==="
aws appstream disassociate-fleet \
  --fleet-name "$FLEET_NAME" \
  --stack-name "$STACK_AS_NAME" \
  --region "$REGION" 2>/dev/null && echo "关联已解除 ✅" || echo "无关联，跳过"

# ---- 3. 删除 Stack ----
echo ""
echo "=== [3/6] 删除 Stack ==="
aws appstream delete-stack \
  --name "$STACK_AS_NAME" \
  --region "$REGION" 2>/dev/null && echo "Stack 删除成功 ✅" || echo "Stack 不存在，跳过"

# ---- 4. 删除 Fleet ----
echo ""
echo "=== [4/6] 删除 Fleet ==="
aws appstream delete-fleet \
  --name "$FLEET_NAME" \
  --region "$REGION" 2>/dev/null && echo "Fleet 删除成功 ✅" || echo "Fleet 不存在，跳过"

# ---- 5. 删除自定义镜像 ----
echo ""
echo "=== [5/6] 删除自定义镜像 ==="
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

# ---- 6. 删除 CloudFormation Stack（含 VPC/S3/IAM/Image Builder） ----
echo ""
echo "=== [6/6] 删除 CloudFormation Stack ==="
CFN_STATE=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$CFN_STATE" == "NOT_FOUND" ]]; then
  echo "CloudFormation Stack 不存在，跳过"
else
  # 清空 S3 Bucket 再删 CFN（否则 S3 非空会删除失败）
  BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstallerBucketName`].OutputValue' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$BUCKET" && "$BUCKET" != "None" ]]; then
    echo "清空 S3 Bucket: $BUCKET ..."
    aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null && echo "S3 清空 ✅" || echo "S3 已为空"
  fi

  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  echo "等待 CloudFormation Stack 删除（约 5-10 分钟）..."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
  echo "CloudFormation Stack 删除完成 ✅"
fi

echo ""
echo "=============================="
echo "✅ 清理完成！所有资源已删除"
echo "=============================="
