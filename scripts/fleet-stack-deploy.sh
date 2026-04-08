#!/bin/bash
# fleet-stack-deploy.sh
# 在自定义镜像制作完成后，用此脚本创建 Fleet 和 Stack
# 前置条件: cfn-workspaces-apps-demo.yaml 已部署完成

set -euo pipefail

REGION="${1:-ap-southeast-1}"
ENV_NAME="${2:-siemens-demo}"
CUSTOM_IMAGE_NAME="${3:-}"  # 必须提供
TEST_USER_EMAIL="${4:-weiyu_nick@hotmail.com}"

if [[ -z "$CUSTOM_IMAGE_NAME" ]]; then
  echo "Usage: $0 <region> <env-name> <custom-image-name> [user-email]"
  echo "Example: $0 ap-southeast-1 siemens-demo siemens-demo-custom-image-v1"
  exit 1
fi

FLEET_NAME="${ENV_NAME}-fleet"
STACK_NAME="${ENV_NAME}-stack"
FLEET_INSTANCE_TYPE="stream.graphics.g4dn.xlarge"

# 从 CFN Outputs 获取 Subnet 和 SG
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

echo "=== 创建 Fleet ==="
echo "Fleet: $FLEET_NAME | Image: $CUSTOM_IMAGE_NAME | Instance: $FLEET_INSTANCE_TYPE"

aws appstream create-fleet \
  --name "$FLEET_NAME" \
  --image-name "$CUSTOM_IMAGE_NAME" \
  --instance-type "$FLEET_INSTANCE_TYPE" \
  --fleet-type "ON_DEMAND" \
  --compute-capacity DesiredInstances=1 \
  --region "$REGION" \
  --vpc-config SubnetIds="$PRIVATE_SUBNET",SecurityGroupIds="$FLEET_SG" \
  --display-name "Siemens Demo Fleet (G4DN)" \
  --description "Mendix Studio Pro + RapidMiner (Altair AI Studio)" \
  --stream-view APP \
  --max-user-duration-in-seconds 9000 \
  --disconnect-timeout-in-seconds 9000 \
  --idle-disconnect-timeout-in-seconds 9000

echo "Fleet 创建成功，等待 RUNNING 状态..."
aws appstream wait fleet-running \
  --names "$FLEET_NAME" \
  --region "$REGION"
echo "Fleet RUNNING ✓"

echo ""
echo "=== 创建 Stack ==="
aws appstream create-stack \
  --name "$STACK_NAME" \
  --display-name "Siemens Demo Stack" \
  --description "WorkSpaces Applications Demo - Mendix + RapidMiner" \
  --region "$REGION" \
  --user-settings \
    Action=CLIPBOARD_COPY_FROM_LOCAL_DEVICE,Permission=ENABLED \
    Action=CLIPBOARD_COPY_TO_LOCAL_DEVICE,Permission=ENABLED \
    Action=FILE_UPLOAD,Permission=ENABLED \
    Action=FILE_DOWNLOAD,Permission=ENABLED \
    Action=PRINTING_TO_LOCAL_DEVICE,Permission=DISABLED

echo "Stack 创建成功 ✓"

echo ""
echo "=== 关联 Fleet 和 Stack ==="
aws appstream associate-fleet \
  --fleet-name "$FLEET_NAME" \
  --stack-name "$STACK_NAME" \
  --region "$REGION"
echo "关联成功 ✓"

echo ""
echo "=== 创建测试用户 ==="
aws appstream create-user \
  --user-name "$TEST_USER_EMAIL" \
  --authentication-type USERPOOL \
  --region "$REGION" \
  --first-name "Test" \
  --last-name "User" 2>/dev/null || echo "用户已存在，跳过创建"

# 启用用户
aws appstream batch-associate-user-stack \
  --user-stack-associations \
    StackName="$STACK_NAME",UserName="$TEST_USER_EMAIL",AuthenticationType=USERPOOL \
  --region "$REGION"
echo "用户 $TEST_USER_EMAIL 已关联到 Stack ✓"

echo ""
echo "=== 生成测试访问 URL (有效期 1 小时) ==="
STREAMING_URL=$(aws appstream create-streaming-url \
  --stack-name "$STACK_NAME" \
  --fleet-name "$FLEET_NAME" \
  --user-id "demo-user" \
  --region "$REGION" \
  --validity 3600 \
  --query 'StreamingURL' \
  --output text)

echo ""
echo "=============================="
echo "✅ 部署完成！"
echo "=============================="
echo "Fleet:        $FLEET_NAME"
echo "Stack:        $STACK_NAME"
echo "测试用户:      $TEST_USER_EMAIL"
echo "Streaming URL: $STREAMING_URL"
echo ""
echo "用户登录方式:"
echo "1. 用户会收到邮件邀请（User Pool 模式）"
echo "2. 或直接使用上方 Streaming URL（临时访问，1小时有效）"
