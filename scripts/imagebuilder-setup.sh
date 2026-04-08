#!/bin/bash
# imagebuilder-setup.sh
# Image Builder 启动后，在 Windows 桌面安装软件前先运行此脚本
# 作用: 生成 Image Builder 的 Streaming URL，供登录使用

REGION="${1:-ap-southeast-1}"
BUILDER_NAME="${2:-siemens-demo-g4dn-builder}"

echo "=== 检查 Image Builder 状态 ==="
STATE=$(aws appstream describe-image-builders \
  --names "$BUILDER_NAME" \
  --region "$REGION" \
  --query 'ImageBuilders[0].State' \
  --output text)
echo "当前状态: $STATE"

if [[ "$STATE" != "RUNNING" ]]; then
  echo "Image Builder 未就绪，等待 RUNNING..."
  aws appstream wait image-builder-running \
    --names "$BUILDER_NAME" \
    --region "$REGION"
  echo "Image Builder RUNNING ✓"
fi

echo ""
echo "=== 生成登录 URL ==="
URL=$(aws appstream create-image-builder-streaming-url \
  --name "$BUILDER_NAME" \
  --region "$REGION" \
  --validity 3600 \
  --query 'StreamingUrl' \
  --output text)

echo ""
echo "=============================="
echo "✅ Image Builder 登录 URL (1小时有效):"
echo "$URL"
echo "=============================="
echo ""
echo "登录后安装步骤："
echo "1. 打开 PowerShell (管理员)"
echo "2. 从 S3 下载安装包:"
echo "   aws s3 cp s3://<your-bucket>/installers/MendixStudioPro-10.24.0.exe C:\\Temp\\"
echo "   aws s3 cp s3://<your-bucket>/installers/altair-aistudio-win64-install.exe C:\\Temp\\"
echo "3. 静默安装 Mendix:"
echo "   C:\\Temp\\MendixStudioPro-10.24.0.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
echo "4. 安装 RapidMiner (Altair AI Studio):"
echo "   C:\\Temp\\altair-aistudio-win64-install.exe -q"
echo "5. 安装完成后，打开 Image Assistant (桌面快捷方式)"
echo "6. 在 Image Assistant 中:"
echo "   - 添加 Mendix Studio Pro 应用"
echo "   - 添加 RapidMiner/Altair AI Studio 应用"
echo "   - 点击 'Create Image'"
echo "   - 镜像名称: siemens-demo-custom-image-v1"
