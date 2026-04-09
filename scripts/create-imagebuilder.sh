#!/bin/bash
# create-imagebuilder.sh
# 创建额外的 Image Builder（复用 CFN 基础设施的网络资源）
# 适用场景：需要多个不同实例系列的 Image Builder 时使用
#   - CFN 只创建一个主 Image Builder
#   - 额外的 Image Builder 通过本脚本创建，共用同一套 VPC/SG
#
# 注意：不同实例系列的镜像不能混用：
#   - Graphics G4dn/G5/G6 Image Builder → 只能用于同系列 GPU Fleet
#   - Standard/Compute/Memory Image Builder → 可用于 Standard/Compute/Memory Fleet
#
# 使用示例（多 Fleet 场景）：
#   CFN 已创建 G4dn Image Builder（GPU 软件用）
#   再用本脚本创建 Standard Image Builder（非 GPU 软件用）：
#   bash create-imagebuilder.sh ap-southeast-1 my-demo standard \
#     stream.standard.xlarge AppStream-WinServer-WinServer2022-10-25-2024

set -euo pipefail

REGION="${1:-ap-southeast-1}"
CFN_STACK_NAME="${2:-my-demo}"      # CFN Stack 名称（读取网络配置）
BUILDER_SUFFIX="${3:-}"             # 必须提供：Image Builder 标识后缀（如 standard / gpu2）
INSTANCE_TYPE="${4:-}"              # 必须提供：实例类型
BASE_IMAGE_NAME="${5:-}"            # 必须提供：对应系列的 Base Image 名称

# ============================================================
# 帮助信息
# ============================================================
usage() {
  echo "Usage: $0 <region> <cfn-stack-name> <builder-suffix> <instance-type> <base-image-name>"
  echo ""
  echo "必填参数:"
  echo "  region          AWS 区域"
  echo "  cfn-stack-name  CloudFormation Stack 名称（提供网络配置）"
  echo "  builder-suffix  Image Builder 标识后缀（如 standard / g5）"
  echo "  instance-type   实例类型（必须与 base-image-name 系列匹配）"
  echo "  base-image-name 对应系列的 Base Image 名称"
  echo ""
  echo "实例系列与 Base Image 对应关系:"
  echo "  stream.standard.*          → AppStream-WinServer-WinServer2022-<DATE>"
  echo "  stream.compute.*           → AppStream-WinServer-WinServer2022-<DATE>"
  echo "  stream.memory.*            → AppStream-WinServer-WinServer2022-<DATE>"
  echo "  stream.graphics.g4dn.*     → AppStream-Graphics-G4dn-WinServer2022-<DATE>"
  echo "  stream.graphics.g5.*       → AppStream-Graphics-G5-WinServer2022-<DATE>"
  echo "  stream.graphics.g6.*       → AppStream-Graphics-G6-WinServer2022-<DATE>"
  echo ""
  echo "查询目标 region 可用的 Base Image："
  echo "  bash scripts/pre-deploy-check.sh <region> <instance-type>"
  echo ""
  echo "示例（为非 GPU Fleet 创建 Standard Image Builder）:"
  echo "  $0 ap-southeast-1 my-demo standard \\"
  echo "    stream.standard.xlarge \\"
  echo "    AppStream-WinServer-WinServer2022-10-25-2024"
  exit 1
}

if [[ -z "$BUILDER_SUFFIX" || -z "$INSTANCE_TYPE" || -z "$BASE_IMAGE_NAME" ]]; then
  usage
fi

BUILDER_NAME="${CFN_STACK_NAME}-${BUILDER_SUFFIX}-builder"

# ============================================================
# 读取 CFN 网络配置
# ============================================================
echo "=== 读取 CloudFormation 网络配置 ==="
PRIVATE_SUBNET=$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnet1Id`].OutputValue' \
  --output text)

BUILDER_SG=$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ImageBuilderSecurityGroupId`].OutputValue' \
  --output text)

IMAGEBUILDER_ROLE=$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ImageBuilderName`].OutputValue' \
  --output text)

# 获取 IAM Role ARN（从现有 Image Builder 读取）
IAM_ROLE_ARN=$(aws appstream describe-image-builders \
  --names "${CFN_STACK_NAME}-builder" --region "$REGION" \
  --query 'ImageBuilders[0].IamRoleArn' --output text 2>/dev/null || echo "")

if [[ -z "$IAM_ROLE_ARN" || "$IAM_ROLE_ARN" == "None" ]]; then
  # 直接构造 IAM Role ARN
  ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
  IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CFN_STACK_NAME}-imagebuilder-role"
fi

echo "CFN Stack:    $CFN_STACK_NAME"
echo "Builder 名称: $BUILDER_NAME"
echo "实例类型:     $INSTANCE_TYPE"
echo "Base Image:   $BASE_IMAGE_NAME"
echo "Subnet:       $PRIVATE_SUBNET"
echo "SG:           $BUILDER_SG"
echo "IAM Role:     $IAM_ROLE_ARN"

# ============================================================
# 检查 Image Builder 是否已存在
# ============================================================
echo ""
echo "=== 检查 Image Builder 状态 ==="

BUILDER_STATE=$(aws appstream describe-image-builders \
  --names "$BUILDER_NAME" --region "$REGION" \
  --query 'ImageBuilders[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$BUILDER_STATE" != "NOT_FOUND" && "$BUILDER_STATE" != "None" ]]; then
  echo "Image Builder '$BUILDER_NAME' 已存在，当前状态: $BUILDER_STATE"
  if [[ "$BUILDER_STATE" == "RUNNING" || "$BUILDER_STATE" == "PENDING" ]]; then
    echo "✅ 可直接使用，无需重新创建"
    echo ""
    echo "生成登录 URL："
    echo "  bash scripts/imagebuilder-setup.sh $REGION $CFN_STACK_NAME $BUILDER_SUFFIX"
    exit 0
  fi
fi

# ============================================================
# 验证 Base Image 可用性
# ============================================================
echo ""
echo "=== 验证 Base Image ==="

IMAGE_STATE=$(aws appstream describe-images \
  --names "$BASE_IMAGE_NAME" --region "$REGION" \
  --query 'Images[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$IMAGE_STATE" == "AVAILABLE" ]]; then
  echo "✅ Base Image 可用: $BASE_IMAGE_NAME"
elif [[ "$IMAGE_STATE" == "NOT_FOUND" ]]; then
  echo "❌ Base Image 不存在: $BASE_IMAGE_NAME"
  echo "   请运行 pre-deploy-check.sh 查询可用的 Base Image："
  echo "   bash scripts/pre-deploy-check.sh $REGION $INSTANCE_TYPE"
  exit 1
else
  echo "⚠️  Base Image 状态异常: $IMAGE_STATE"
  exit 1
fi

# ============================================================
# 创建 Image Builder
# ============================================================
echo ""
echo "=== 创建 Image Builder ==="

aws appstream create-image-builder \
  --name "$BUILDER_NAME" \
  --display-name "${CFN_STACK_NAME} ${BUILDER_SUFFIX} Image Builder" \
  --description "Image Builder for ${CFN_STACK_NAME}/${BUILDER_SUFFIX} (${INSTANCE_TYPE})" \
  --image-name "$BASE_IMAGE_NAME" \
  --instance-type "$INSTANCE_TYPE" \
  --region "$REGION" \
  --vpc-config SubnetIds="$PRIVATE_SUBNET",SecurityGroupIds="$BUILDER_SG" \
  --iam-role-arn "$IAM_ROLE_ARN" \
  --enable-default-internet-access false \
  --output json > /dev/null

echo "Image Builder 创建中..."

# 等待 RUNNING 状态
while true; do
  STATE=$(aws appstream describe-image-builders \
    --names "$BUILDER_NAME" --region "$REGION" \
    --query 'ImageBuilders[0].State' --output text 2>/dev/null || echo "PENDING")
  echo "  状态: $STATE"
  [[ "$STATE" == "RUNNING" ]] && break
  [[ "$STATE" == "FAILED" ]] && echo "❌ Image Builder 创建失败" && exit 1
  sleep 30
done

# ============================================================
# 生成登录 URL
# ============================================================
echo ""
echo "=== 生成 Image Builder 登录 URL ==="

LOGIN_URL=$(aws appstream create-streaming-url \
  --stack-name "" \
  --fleet-name "" \
  --region "$REGION" 2>/dev/null || true)

# 使用 image builder streaming URL API
LOGIN_URL=$(aws appstream create-image-builder-streaming-url \
  --name "$BUILDER_NAME" \
  --validity 3600 \
  --region "$REGION" \
  --query 'StreamingURL' --output text 2>/dev/null || echo "")

echo ""
echo "=============================="
echo "✅ Image Builder 创建完成！"
echo "=============================="
echo "名称:       $BUILDER_NAME"
echo "实例类型:   $INSTANCE_TYPE"
echo "状态:       RUNNING"
echo ""
if [[ -n "$LOGIN_URL" ]]; then
  echo "登录 URL（1小时有效）:"
  echo "$LOGIN_URL"
  echo ""
fi
echo "下一步："
echo "  1. 用登录 URL 进入 Windows 桌面"
echo "  2. 安装所需软件"
echo "  3. 打开 Image Assistant → Add App → Create Image"
echo "  4. 镜像名建议: ${CFN_STACK_NAME}-${BUILDER_SUFFIX}-image-v1"
echo ""
echo "镜像制作完成后创建 Fleet："
echo "  bash scripts/fleet-stack-deploy.sh $REGION $CFN_STACK_NAME \\"
echo "    ${CFN_STACK_NAME}-${BUILDER_SUFFIX}-image-v1 $BUILDER_SUFFIX \\"
echo "    2 20 $INSTANCE_TYPE ON_DEMAND"
