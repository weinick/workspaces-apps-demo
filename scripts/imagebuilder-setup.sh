#!/bin/bash
# imagebuilder-setup.sh
# 一站式 Image Builder 工作流：上传安装包 → 启动 → 登录安装 → 监控镜像制作
#
# 用法: imagebuilder-setup.sh <region> <stack-name> [presign-expires] [installer-filter] [builder-suffix]
#   region:           AWS Region（默认 ap-southeast-1）
#   stack-name:       CloudFormation Stack 名称（必填）
#   presign-expires:  可选，Presigned URL 有效期秒数（默认 3600）
#   installer-filter: 可选，按文件名关键字过滤安装包
#   builder-suffix:   可选，副 Image Builder suffix（不传则用主 Image Builder）

set -euo pipefail

REGION="${1:-ap-southeast-1}"
STACK_NAME="${2:-siemens-demo}"
PRESIGN_EXPIRES="${3:-3600}"
INSTALLER_FILTER="${4:-}"
BUILDER_SUFFIX="${5:-}"

# ============================================================
# 工具函数
# ============================================================
header()  { echo ""; echo "══════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════"; }
section() { echo ""; echo "── $1 ──"; }

header "WorkSpaces Applications — Image Builder Setup"
echo ""
echo "  Region:     $REGION"
echo "  Stack:      $STACK_NAME"

# ============================================================
# Step 1: 读取 CloudFormation 配置
# ============================================================
section "Step 1: 读取 CloudFormation 配置"

BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstallerBucketName`].OutputValue' \
  --output text 2>/dev/null || true)

BUILDER_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ImageBuilderName`].OutputValue' \
  --output text 2>/dev/null || true)

if [[ -z "$BUCKET" || "$BUCKET" == "None" ]]; then
  echo "❌ 无法获取 S3 Bucket，请确认 Stack '$STACK_NAME' 已部署完成"; exit 1
fi
if [[ -z "$BUILDER_NAME" || "$BUILDER_NAME" == "None" ]]; then
  echo "❌ 无法获取 Image Builder 名称，请确认 Stack '$STACK_NAME' 已部署完成"; exit 1
fi

if [[ -n "$BUILDER_SUFFIX" ]]; then
  BUILDER_NAME="${STACK_NAME}-${BUILDER_SUFFIX}-builder"
fi

echo "  S3 Bucket:      $BUCKET"
echo "  Image Builder:  $BUILDER_NAME"

# ============================================================
# Step 2: 上传安装包到 S3
# ============================================================
section "Step 2: 上传安装包到 S3"

echo ""
echo "  请确保已将安装包上传到 S3（如尚未上传，按 Ctrl+C 中断后执行）："
echo ""
echo "    aws s3 cp <file> s3://$BUCKET/installers/ --region $REGION"
echo "    # 批量: aws s3 cp ./installers/ s3://$BUCKET/installers/ --region $REGION --recursive"
echo ""
read -r -p "  已上传？按 Enter 继续: "

# 检查安装包
INSTALLERS=$(aws s3 ls "s3://$BUCKET/installers/" --region "$REGION" 2>/dev/null || true)

if [[ -z "$INSTALLERS" ]]; then
  # 自动检测根目录文件
  ROOT_FILES=$(aws s3 ls "s3://$BUCKET/" --region "$REGION" 2>/dev/null | grep -v 'PRE ' || true)
  if [[ -n "$ROOT_FILES" ]]; then
    echo ""
    echo "  💡 检测到文件在 Bucket 根目录，自动移动到 installers/..."
    while IFS= read -r line; do
      FNAME=$(echo "$line" | awk '{print $4}')
      [[ -z "$FNAME" ]] && continue
      echo "     移动: $FNAME → installers/$FNAME"
      aws s3 mv "s3://$BUCKET/$FNAME" "s3://$BUCKET/installers/$FNAME" --region "$REGION" > /dev/null
    done <<< "$ROOT_FILES"
    INSTALLERS=$(aws s3 ls "s3://$BUCKET/installers/" --region "$REGION" 2>/dev/null || true)
  fi
  if [[ -z "$INSTALLERS" ]]; then
    echo ""
    echo "  ❌ S3 中没有安装包，请上传后重新运行"
    echo "     aws s3 cp <file> s3://$BUCKET/installers/ --region $REGION"
    exit 1
  fi
fi

echo ""
echo "  ✅ 找到安装包："
echo "$INSTALLERS" | while IFS= read -r line; do
  FNAME=$(echo "$line" | awk '{print $4}')
  [[ -n "$FNAME" ]] && echo "     📦 $FNAME"
done

# ============================================================
# Step 3: 生成 Presigned URL & PowerShell 下载命令
# ============================================================
section "Step 3: 生成 PowerShell 下载命令"

echo ""
PRESIGN_CMDS=""
MATCHED=0
while IFS= read -r line; do
  FILENAME=$(echo "$line" | awk '{print $4}')
  [[ -z "$FILENAME" ]] && continue

  if [[ -n "$INSTALLER_FILTER" ]]; then
    FILENAME_LOWER=$(echo "$FILENAME" | tr '[:upper:]' '[:lower:]')
    FILTER_LOWER=$(echo "$INSTALLER_FILTER" | tr '[:upper:]' '[:lower:]')
    [[ "$FILENAME_LOWER" != *"$FILTER_LOWER"* ]] && continue
  fi

  MATCHED=$((MATCHED+1))
  PRESIGNED_URL=$(aws s3 presign "s3://$BUCKET/installers/$FILENAME" \
    --region "$REGION" --expires-in "$PRESIGN_EXPIRES")
  SAFE_NAME=$(echo "$FILENAME" | sed 's/[^a-zA-Z0-9._-]/-/g')

  PRESIGN_CMDS="${PRESIGN_CMDS}# 下载 $FILENAME
Invoke-WebRequest -Uri \"$PRESIGNED_URL\" -OutFile \"\$env:USERPROFILE\\Downloads\\$SAFE_NAME\"

"
done <<< "$INSTALLERS"

if [[ $MATCHED -eq 0 ]]; then
  echo "  ❌ 没有匹配关键字 \"$INSTALLER_FILTER\" 的安装包"
  exit 1
fi

echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │ 📋 请保存以下命令，登录 Image Builder 后在            │"
echo "  │    PowerShell（管理员）中粘贴执行                     │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "$PRESIGN_CMDS"
echo "  ⬇️  下载后操作流程：安装软件 → 打开 Image Assistant → Add App → Create Image"
echo "  （详细步骤见 Step 4 完成后的操作指引）"

# ============================================================
# Step 4: 启动 Image Builder & 生成登录 URL
# ============================================================
section "Step 4: 启动 Image Builder"

STATE=$(aws appstream describe-image-builders \
  --names "$BUILDER_NAME" --region "$REGION" \
  --query 'ImageBuilders[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$STATE" == "NOT_FOUND" || "$STATE" == "None" ]]; then
  echo "  ❌ Image Builder '$BUILDER_NAME' 不存在"; exit 1
fi

if [[ "$STATE" == "SNAPSHOTTING" ]]; then
  echo "  ⚠️  Image Builder 正在打包镜像，请等待完成后重新运行"
  exit 0
elif [[ "$STATE" == "STOPPED" ]]; then
  echo "  Image Builder 已停止，正在启动..."
  aws appstream start-image-builder --name "$BUILDER_NAME" --region "$REGION" > /dev/null
fi

if [[ "$STATE" != "RUNNING" ]]; then
  echo "  等待 RUNNING 状态（约 5-10 分钟）..."
  while true; do
    sleep 30
    STATE=$(aws appstream describe-image-builders \
      --names "$BUILDER_NAME" --region "$REGION" \
      --query 'ImageBuilders[0].State' --output text 2>/dev/null || echo "UNKNOWN")
    echo "  状态: $STATE"
    [[ "$STATE" == "RUNNING" ]] && break
    [[ "$STATE" == "FAILED" ]] && echo "  ❌ 启动失败" && exit 1
  done
fi

echo "  ✅ Image Builder RUNNING"
echo ""

LOGIN_URL=$(aws appstream create-image-builder-streaming-url \
  --name "$BUILDER_NAME" --region "$REGION" \
  --validity 3600 --query 'StreamingURL' --output text)

# ============================================================
# 汇总：操作步骤
# ============================================================
header "✅ 准备完成！请按以下步骤操作"

echo ""
echo "  1️⃣  在浏览器打开以下 URL 登录 Image Builder："
echo ""
echo "     $LOGIN_URL"
echo ""
echo "  2️⃣  登录后打开 PowerShell（管理员），粘贴 Step 3 输出的下载命令"
echo ""
echo "  3️⃣  安装软件后，打开桌面的 Image Assistant："
echo "     → Add App → 选择已安装的应用 → Create Image"
echo "     → 输入镜像名称（如 my-app-gpu-image-v1）→ 确认"
echo ""
echo "  4️⃣  完成后回到此终端，按 Enter 开始监控镜像制作进度"
echo ""

# ============================================================
# Step 5: 等待用户操作完成 → 监控镜像制作
# ============================================================
read -r -p "  已在 Image Builder 中点击 Create Image？按 Enter 开始监控: "

section "Step 5: 监控镜像制作"
echo ""
echo "  正在监控 Image Builder 状态（镜像制作约 20-30 分钟）..."
echo "  状态变化: RUNNING → SNAPSHOTTING → STOPPED（完成）"
echo ""

SNAPSHOT_START=""
while true; do
  STATE=$(aws appstream describe-image-builders \
    --names "$BUILDER_NAME" --region "$REGION" \
    --query 'ImageBuilders[0].State' --output text 2>/dev/null || echo "UNKNOWN")

  TIMESTAMP=$(date '+%H:%M:%S')

  if [[ "$STATE" == "SNAPSHOTTING" && -z "$SNAPSHOT_START" ]]; then
    SNAPSHOT_START=$(date +%s)
    echo "  [$TIMESTAMP] 📸 镜像打包中 (SNAPSHOTTING)..."
  elif [[ "$STATE" == "SNAPSHOTTING" && -n "$SNAPSHOT_START" ]]; then
    ELAPSED=$(( $(date +%s) - SNAPSHOT_START ))
    ELAPSED_MIN=$((ELAPSED / 60))
    echo "  [$TIMESTAMP] 📸 镜像打包中... (已用 ${ELAPSED_MIN} 分钟)"
  elif [[ "$STATE" == "STOPPED" ]]; then
    echo "  [$TIMESTAMP] ✅ 镜像制作完成！Image Builder 已自动停止"
    break
  elif [[ "$STATE" == "RUNNING" ]]; then
    echo "  [$TIMESTAMP] ⏳ 等待 Create Image 操作... (当前 RUNNING)"
  else
    echo "  [$TIMESTAMP] 状态: $STATE"
  fi

  sleep 30
done

# 查询刚制作的镜像
echo ""
section "镜像信息"
echo ""
echo "  最近创建的自定义镜像："
aws appstream describe-images \
  --type PRIVATE --region "$REGION" \
  --query 'Images[*].{Name:Name,State:State,Created:CreatedTime}' \
  --output table 2>/dev/null || echo "  （查询失败，请手动确认）"

# 获取最新的自定义镜像名（按创建时间倒序）
LATEST_IMAGE=$(aws appstream describe-images \
  --type PRIVATE --region "$REGION" \
  --query 'sort_by(Images, &CreatedTime)[-1].Name' \
  --output text 2>/dev/null || echo "")

echo ""
header "🎉 下一步"
echo ""
echo "  1. 删除 Image Builder（停止计费）："
echo ""
echo "     bash scripts/delete-imagebuilder.sh $REGION $STACK_NAME"
echo ""
echo "  2. 部署 Fleet（region/stack-name/image 已预填，按需修改其余参数）："
echo ""
if [[ -n "$LATEST_IMAGE" && "$LATEST_IMAGE" != "None" ]]; then
  echo "     bash scripts/fleet-stack-deploy.sh $REGION $STACK_NAME $LATEST_IMAGE <fleet-suffix> 1 2 <instance-type>"
else
  echo "     bash scripts/fleet-stack-deploy.sh $REGION $STACK_NAME <image-name> <fleet-suffix> 1 2 <instance-type>"
fi
echo ""
echo "     参数说明："
echo "       fleet-suffix:   Fleet 名称后缀（如 gpu、standard）"
echo "       1 2:            最小/最大实例数（按需调整）"
echo "       instance-type:  实例类型（如 stream.graphics.g4dn.xlarge）"
echo ""
