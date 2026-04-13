#!/bin/bash
# imagebuilder-setup.sh
# 功能:
#   1. 检查 S3 中的安装包并生成 Presigned URL（供 Image Builder 内下载使用）
#   2. 等待 Image Builder RUNNING 后生成登录 URL
#
# 用法: imagebuilder-setup.sh <region> <stack-name> [presign-expires] [installer-filter] [builder-suffix]
#   installer-filter: 可选，按文件名关键字过滤，只输出匹配的安装包 URL
#                     例如传入 "mendix" 则只输出文件名包含 "mendix" 的安装包 URL
#                     如果不传则输出全部安装包
#   builder-suffix:   可选，指定副 Image Builder 的 suffix（由 create-imagebuilder.sh 创建）
#                     不传则默认使用主 Image Builder（从 CFN Stack 读取）

set -euo pipefail

REGION="${1:-ap-southeast-1}"
STACK_NAME="${2:-siemens-demo}"
PRESIGN_EXPIRES="${3:-3600}"  # Presigned URL 有效期（秒），默认1小时
INSTALLER_FILTER="${4:-}"     # 可选：文件名关键字过滤
BUILDER_SUFFIX="${5:-}"       # 可选：副 Image Builder suffix（不传则用主 Image Builder）

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
  --output text 2>/dev/null || true)

BUILDER_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ImageBuilderName`].OutputValue' \
  --output text 2>/dev/null || true)

if [[ -z "$BUCKET" || "$BUCKET" == "None" ]]; then
  echo "❌ 无法从 CloudFormation Stack '$STACK_NAME' 获取 S3 Bucket 信息"
  echo "   请确认 Stack 名称正确且已部署完成"
  exit 1
fi

if [[ -z "$BUILDER_NAME" || "$BUILDER_NAME" == "None" ]]; then
  echo "❌ 无法从 CloudFormation Stack '$STACK_NAME' 获取 Image Builder 名称"
  echo "   请确认 Stack 名称正确且已部署完成"
  exit 1
fi

# 如果传入了 builder-suffix，切换到副 Image Builder
if [[ -n "$BUILDER_SUFFIX" ]]; then
  BUILDER_NAME="${STACK_NAME}-${BUILDER_SUFFIX}-builder"
  echo "S3 Bucket:     $BUCKET"
  echo "Image Builder: $BUILDER_NAME（副，suffix=${BUILDER_SUFFIX}）"
else
  echo "S3 Bucket:     $BUCKET"
  echo "Image Builder: $BUILDER_NAME（主）"
fi
echo ""

# 提醒用户上传安装包
echo "=== 上传安装包 ==="
echo "请确保已将软件安装包上传到 S3（如尚未上传，按 Ctrl+C 中断后执行以下命令）："
echo ""
echo "  aws s3 cp <installer-file> s3://$BUCKET/installers/ --region $REGION"
echo ""
echo "  示例：aws s3 cp MyApp-Setup.exe s3://$BUCKET/installers/ --region $REGION"
echo "  批量：aws s3 cp ./installers/ s3://$BUCKET/installers/ --region $REGION --recursive"
echo ""
read -r -p "已上传安装包？按 Enter 继续，Ctrl+C 中断: "
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
if [[ -z "$INSTALLER_FILTER" ]]; then
  echo "  💡 提示：可传入第 4 个参数按关键字过滤，只输出指定安装包的 URL"
  echo "  例: bash scripts/imagebuilder-setup.sh $REGION $STACK_NAME $PRESIGN_EXPIRES <关键字>"
  echo ""
fi

echo "=== 生成 Presigned URLs（有效期 ${PRESIGN_EXPIRES} 秒）==="
echo ""
echo "ℹ️  以下是安装包的临时下载链接，进入 Image Builder Windows 桌面后需要在 PowerShell 中运行下方的下载命令（请提前保存）："
echo ""

if [[ -n "$INSTALLER_FILTER" ]]; then
  echo "  🔍 安装包过滤关键字: \"$INSTALLER_FILTER\" （大小写不敏感）"
  echo ""
fi

PRESIGN_CMDS=""
MATCHED=0
while IFS= read -r line; do
  # 提取文件名
  FILENAME=$(echo "$line" | awk '{print $4}')
  if [[ -z "$FILENAME" ]]; then continue; fi

  # 如果设置了 filter，跳过不匹配的文件（大小写不敏感）
  if [[ -n "$INSTALLER_FILTER" ]]; then
    FILENAME_LOWER=$(echo "$FILENAME" | tr '[:upper:]' '[:lower:]')
    FILTER_LOWER=$(echo "$INSTALLER_FILTER" | tr '[:upper:]' '[:lower:]')
    if [[ "$FILENAME_LOWER" != *"$FILTER_LOWER"* ]]; then
      continue
    fi
  fi

  MATCHED=$((MATCHED+1))

  S3_KEY="installers/$FILENAME"
  PRESIGNED_URL=$(aws s3 presign "s3://$BUCKET/$S3_KEY" \
    --region "$REGION" \
    --expires-in "$PRESIGN_EXPIRES")

  echo "📦 $FILENAME"
  echo "   Presigned URL:"
  echo "   $PRESIGNED_URL"
  echo ""

  # 生成 PowerShell 下载命令（使用 $env:USERPROFILE 自动适配当前用户路径）
  SAFE_NAME=$(echo "$FILENAME" | sed 's/[^a-zA-Z0-9._-]/-/g')
  PRESIGN_CMDS="${PRESIGN_CMDS}
# 下载 $FILENAME
Invoke-WebRequest -Uri \"$PRESIGNED_URL\" -OutFile \"\$env:USERPROFILE\\Downloads\\$SAFE_NAME\"
"
done <<< "$INSTALLERS"

if [[ $MATCHED -eq 0 ]]; then
  echo "❌ 没有找到匹配关键字 \"$INSTALLER_FILTER\" 的安装包"
  echo "   S3 中现有文件："
  aws s3 ls "s3://$BUCKET/installers/" --region "$REGION" | awk '{print "   - " $4}'
  exit 1
fi

echo "=============================="
echo "📋 Image Builder 内 PowerShell 下载命令（复制到 Image Builder 使用）："
echo "=============================="
echo ""
echo "# 下载到 Downloads 文件夹"
echo "$PRESIGN_CMDS"
echo ""
echo "=============================="
echo "📍 下一步：登录 Image Builder Windows 桌面"
echo "=============================="
echo ""
echo "   脚本正在启动 Image Builder，就绪后会输出登录链接。"
echo "   登录后第一步：打开 PowerShell（管理员），粘贴上方的下载命令，下载安装包。"
echo ""

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

if [[ "$STATE" == "SNAPSHOTTING" ]]; then
  echo "⚠️  Image Builder 正在打包镜像（SNAPSHOTTING），请等待镜像制作完成后再运行此脚本。"
  echo "   镜像打包约需 20-30 分钟，完成后 Image Builder 会自动变为 STOPPED。"
  echo ""
  echo "   查看状态："
  echo "   aws appstream describe-image-builders --names $BUILDER_NAME --region $REGION --query 'ImageBuilders[0].State' --output text"
  exit 0
elif [[ "$STATE" == "STOPPED" ]]; then
  echo "Image Builder 处于 STOPPED 状态，正在启动..."
  aws appstream start-image-builder \
    --name "$BUILDER_NAME" \
    --region "$REGION" > /dev/null
  echo "已触发启动，等待 RUNNING（约 5-10 分钟）..."
elif [[ "$STATE" != "RUNNING" ]]; then
  echo "等待 Image Builder RUNNING（当前: $STATE）..."
fi

if [[ "$STATE" != "RUNNING" && "$STATE" != "SNAPSHOTTING" ]]; then
  while true; do
    sleep 30
    STATE=$(aws appstream describe-image-builders \
      --names "$BUILDER_NAME" \
      --region "$REGION" \
      --query 'ImageBuilders[0].State' \
      --output text 2>/dev/null || echo "UNKNOWN")
    echo "  状态: $STATE"
    [[ "$STATE" == "RUNNING" ]] && break
    [[ "$STATE" == "FAILED" ]] && echo "❌ Image Builder 启动失败" && exit 1
  done
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
echo "2️⃣  登录后，立即打开 PowerShell（管理员），粘贴脚本开头输出的 PowerShell 下载命令，下载安装包到 Downloads 文件夹"
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
