#!/bin/bash
# imagebuilder-setup.sh
# 功能:
#   1. 检查 S3 中的安装包并生成 Presigned URL（供 Image Builder 内下载使用）
#   2. 等待 Image Builder RUNNING 后生成登录 URL

set -euo pipefail

REGION="${1:-ap-southeast-1}"
STACK_NAME="${2:-siemens-demo}"
PRESIGN_EXPIRES="${3:-3600}"  # Presigned URL 有效期（秒），默认1小时

echo "=============================="
echo "WorkSpaces Applications Demo"
echo "Image Builder Setup Script"
echo "=============================="
echo ""

# 从 CFN Outputs 获取 S3 Bucket 和 Image Builder 名称
echo "=== 读取 CloudFormation 配置 ==="
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstallerBucketName`].OutputValue' \
  --output text)

BUILDER_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ImageBuilderName`].OutputValue' \
  --output text)

echo "S3 Bucket:     $BUCKET"
echo "Image Builder: $BUILDER_NAME"
echo ""

# 列出 S3 中的安装包并生成 Presigned URL
echo "=== 检查 S3 安装包 ==="
INSTALLERS=$(aws s3 ls "s3://$BUCKET/installers/" --region "$REGION" 2>/dev/null || true)

if [[ -z "$INSTALLERS" ]]; then
  echo "⚠️  s3://$BUCKET/installers/ 中没有找到安装包"
  echo ""

  # 自动检测：文件是否被上传到根目录
  ROOT_FILES=$(aws s3 ls "s3://$BUCKET/" --region "$REGION" 2>/dev/null | grep -v 'PRE ' || true)
  if [[ -n "$ROOT_FILES" ]]; then
    echo "💡 检测到文件上传在 Bucket 根目录，正在自动移动到 installers/ 子目录..."
    echo ""
    while IFS= read -r line; do
      FNAME=$(echo "$line" | awk '{print $4}')
      if [[ -z "$FNAME" ]]; then continue; fi
      echo "   移动: $FNAME → installers/$FNAME"
      aws s3 mv "s3://$BUCKET/$FNAME" "s3://$BUCKET/installers/$FNAME" --region "$REGION" > /dev/null
    done <<< "$ROOT_FILES"
    echo ""
    echo "✅ 移动完成，重新检查安装包..."
    INSTALLERS=$(aws s3 ls "s3://$BUCKET/installers/" --region "$REGION" 2>/dev/null || true)
  fi

  if [[ -z "$INSTALLERS" ]]; then
    echo "❌ S3 中没有找到安装包，请先上传到正确路径："
    echo ""
    echo "  aws s3 cp <installer.exe> s3://$BUCKET/installers/ --region $REGION"
    echo ""
    echo "  ⚠️  注意：必须上传到 installers/ 子目录，不能直接放在 Bucket 根目录"
    echo ""
    exit 1
  fi
fi

echo "找到以下安装包："
echo "$INSTALLERS"
echo ""

echo "=== 生成 Presigned URLs（有效期 ${PRESIGN_EXPIRES} 秒）==="
echo ""

PRESIGN_CMDS=""
while IFS= read -r line; do
  # 提取文件名
  FILENAME=$(echo "$line" | awk '{print $4}')
  if [[ -z "$FILENAME" ]]; then continue; fi

  S3_KEY="installers/$FILENAME"
  PRESIGNED_URL=$(aws s3 presign "s3://$BUCKET/$S3_KEY" \
    --region "$REGION" \
    --expires-in "$PRESIGN_EXPIRES")

  echo "📦 $FILENAME"
  echo "   Presigned URL:"
  echo "   $PRESIGNED_URL"
  echo ""

  # 生成 PowerShell 下载命令
  SAFE_NAME=$(echo "$FILENAME" | sed 's/[^a-zA-Z0-9._-]/-/g')
  PRESIGN_CMDS="${PRESIGN_CMDS}
# 下载 $FILENAME
Invoke-WebRequest -Uri \"$PRESIGNED_URL\" -OutFile \"C:\\Users\\Administrator\\Downloads\\$SAFE_NAME\"
"
done <<< "$INSTALLERS"

echo "=============================="
echo "📋 Image Builder 内 PowerShell 下载命令（复制到 Image Builder 使用）："
echo "=============================="
echo ""
echo "# 下载到 Downloads 文件夹"
echo "$PRESIGN_CMDS"

# 检查并等待 Image Builder RUNNING
echo ""
echo "=== 检查 Image Builder 状态 ==="
STATE=$(aws appstream describe-image-builders \
  --names "$BUILDER_NAME" \
  --region "$REGION" \
  --query 'ImageBuilders[0].State' \
  --output text 2>/dev/null || echo "NOT_FOUND")

echo "当前状态: $STATE"

if [[ "$STATE" == "NOT_FOUND" || "$STATE" == "None" ]]; then
  echo "❌ Image Builder 不存在，请先部署 CloudFormation Stack"
  exit 1
fi

if [[ "$STATE" != "RUNNING" ]]; then
  echo "等待 Image Builder RUNNING..."
  aws appstream wait image-builder-running \
    --names "$BUILDER_NAME" \
    --region "$REGION"
  echo "Image Builder RUNNING ✅"
fi

echo ""
echo "=== 生成 Image Builder 登录 URL（有效期 1 小时）==="
LOGIN_URL=$(aws appstream create-image-builder-streaming-url \
  --name "$BUILDER_NAME" \
  --region "$REGION" \
  --validity 3600 \
  --query 'StreamingURL' \
  --output text)

echo ""
echo "=============================="
echo "✅ 准备完成！请按以下步骤操作："
echo "=============================="
echo ""
echo "1️⃣  在浏览器打开以下 URL，登录 Image Builder Windows 桌面："
echo ""
echo "   $LOGIN_URL"
echo ""
echo "2️⃣  登录后打开 PowerShell（管理员），粘贴上方的下载命令，下载安装包"
echo ""
echo "3️⃣  安装完成后，打开桌面的 Image Assistant："
echo "   - 点击 'Add App'，添加已安装的应用程序（需要能找到 .exe 启动路径）"
echo "   - 点击 'Create Image'"
echo "   - 镜像名称填写: <自定义镜像名，如 my-demo-gpu-image-v1>"
echo "   - 点击确认，等待打包完成（约 20-30 分钟）"
echo ""
echo "   ⚠️  如需制作多个镜像（如 GPU + Standard），请串行操作："
echo "      第一个镜像做完后，Image Builder 会停机。"
echo "      用 create-imagebuilder.sh 启动新的 Image Builder 再做第二个。"
echo ""
echo "4️⃣  镜像制作完成后，立即删除 Image Builder 停止计费："
echo ""
echo "   bash scripts/delete-imagebuilder.sh $REGION $STACK_NAME"
echo ""
echo "5️⃣  再执行以下命令部署 Fleet 和 Stack："
echo ""
echo "   bash scripts/fleet-stack-deploy.sh $REGION $STACK_NAME <image-name> <fleet-suffix> <min> <max> <instance-type>"
echo ""
