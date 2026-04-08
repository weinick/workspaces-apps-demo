# WorkSpaces Applications Demo 部署说明
## Mendix Studio Pro + RapidMiner (Altair AI Studio) on AWS

---

## 文件清单

| 文件 | 说明 |
|------|------|
| `cfn-workspaces-apps-demo.yaml` | CloudFormation 主模板（VPC + Image Builder） |
| `fleet-stack-deploy.sh` | Fleet + Stack + 用户关联脚本（镜像制作完成后执行） |
| `imagebuilder-setup.sh` | 生成 Image Builder 登录 URL 的脚本 |

---

## 部署流程概览

```
Step 1: 准备软件安装包
Step 2: 部署 CloudFormation（VPC + Image Builder）
Step 3: 登录 Image Builder 安装软件 + 制作镜像
Step 4: 执行 fleet-stack-deploy.sh 创建 Fleet + Stack
Step 5: 用户访问验证
```

---

## Step 1：准备软件安装包

在本机下载以下软件的 Windows 安装包：

### Mendix Studio Pro
- 下载地址：https://marketplace.mendix.com/link/studiopro（需登录 Mendix 账号）
- 推荐版本：10.24.x LTS
- 文件名示例：`MendixStudioPro-10.24.0.exe`

### RapidMiner Studio（现为 Altair AI Studio）
- 下载地址：https://altair.com/altair-rapidminer（需注册 Altair 账号）
- 文件名示例：`altair-aistudio-win64-install.exe`

上传到 S3（CloudFormation 部署后会创建 Bucket）：

```bash
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name siemens-demo \
  --region ap-southeast-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`InstallerBucketName`].OutputValue' \
  --output text)

aws s3 cp MendixStudioPro-10.24.0.exe s3://$BUCKET_NAME/installers/
aws s3 cp altair-aistudio-win64-install.exe s3://$BUCKET_NAME/installers/
```

---

## Step 2：部署 CloudFormation

```bash
aws cloudformation deploy \
  --template-file cfn-workspaces-apps-demo.yaml \
  --stack-name siemens-demo \
  --region ap-southeast-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName=siemens-demo \
    InstallerBucketName=siemens-demo-installers \
    MendixInstallerKey=installers/MendixStudioPro-10.24.0.exe \
    RapidMinerInstallerKey=installers/altair-aistudio-win64-install.exe
```

部署时间约 **10-15 分钟**（主要等待 Image Builder 启动）。

> ⚠️ 前置条件：
> - 区域 ap-southeast-1 已有 `Graphics G4DN xlarge` 配额（Image Builder ≥1，Fleet ≥1）
> - IAM Role 有 CloudFormation、EC2、AppStream、S3、IAM 权限

---

## Step 3：登录 Image Builder 安装软件

### 3.1 上传软件安装包到 S3

先将安装包上传到 CloudFormation 创建的 S3 Bucket：

```bash
# 获取 Bucket 名称
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name siemens-demo \
  --region ap-southeast-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`InstallerBucketName`].OutputValue' \
  --output text)

# 上传安装包（按需上传，支持一个或多个）
aws s3 cp MendixStudioPro-10.24.0.exe s3://$BUCKET/installers/ --region ap-southeast-1
aws s3 cp ai-studio-win64-install.exe s3://$BUCKET/installers/ --region ap-southeast-1
```

### 3.2 生成 Presigned URL + Image Builder 登录 URL

```bash
bash imagebuilder-setup.sh ap-southeast-1 siemens-demo
```

脚本会自动完成：
- ✅ 检查 S3 中的安装包
- ✅ 为每个安装包生成 **Presigned URL**（1小时有效，无需 AWS 凭证即可下载）
- ✅ 生成 Image Builder **登录 URL**
- ✅ 输出可直接粘贴到 Image Builder 内的 PowerShell 下载命令

### 3.3 在 Windows 桌面安装软件

用登录 URL 进入 Image Builder Windows 桌面后，打开 PowerShell（管理员），将脚本输出的下载命令粘贴执行（使用 Presigned URL 下载，无需配置 AWS 凭证）：

```powershell
# 示例（脚本会自动生成实际命令）
New-Item -ItemType Directory -Force -Path C:\Temp
Invoke-WebRequest -Uri "<presigned-url>" -OutFile "C:\Temp\installer.exe"

# 静默安装 Mendix Studio Pro
C:\Temp\MendixStudioPro-10.24.0.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART

# 安装 Altair AI Studio
C:\Temp\ai-studio-installer.exe -q
```

### 3.3 使用 Image Assistant 打包镜像

1. 双击桌面上的 **Image Assistant** 图标
2. 点击 **"Add App"**，依次添加：
   - Mendix Studio Pro（`C:\Program Files\Mendix\Studio Pro 10.24.0\studiopro.exe`）
   - Altair AI Studio（`C:\Program Files\Altair\AIStudio\aistudio.exe`）
3. 配置好应用图标和显示名称后点击 **"Next"**
4. 在 **"Create Image"** 页面输入镜像名称：`siemens-demo-custom-image-v1`
5. 点击 **"Create Image"** — 实例会自动关闭并开始制作镜像

镜像制作时间约 **20-30 分钟**。

查看镜像状态：
```bash
aws appstream describe-images \
  --names siemens-demo-custom-image-v1 \
  --region ap-southeast-1 \
  --query 'Images[0].State'
```

---

## Step 4：创建 Fleet + Stack + 关联用户

镜像状态变为 `AVAILABLE` 后执行：

```bash
bash fleet-stack-deploy.sh \
  <region> \
  <env-name> \
  <custom-image-name> \
  <test-user-email>

# 示例：
# bash fleet-stack-deploy.sh ap-southeast-1 siemens-demo siemens-demo-custom-image-v1 user@example.com
```

脚本会自动完成：
- ✅ 创建 G4DN xlarge Fleet（ON_DEMAND 模式）
- ✅ 创建 Stack（配置剪贴板/文件上传下载权限）
- ✅ 关联 Fleet 和 Stack
- ✅ 创建测试用户（由 `<test-user-email>` 参数指定）
- ✅ 输出 Streaming URL

---

## Step 5：用户访问

### 方式一：User Pool 邀请邮件
指定的测试用户邮箱会收到邀请邮件，点击链接设置密码后即可访问。

### 方式二：临时 Streaming URL（测试用）
脚本执行完成后会输出一个临时 URL（1小时有效），直接在浏览器中打开即可访问应用。

---

## 架构说明

```
Internet
    │
    ├── Public Subnet (NAT Gateway)
    │
    └── Private Subnet
            ├── Image Builder (stream.graphics.g4dn.xlarge)
            └── Fleet Instance (stream.graphics.g4dn.xlarge)
                    ├── Mendix Studio Pro 10.24.x
                    └── Altair AI Studio (RapidMiner)
```

- **网络**：Image Builder 和 Fleet 放在私有子网，通过 NAT Gateway 访问互联网
- **实例类型**：`stream.graphics.g4dn.xlarge`（4 vCPU, 16GB RAM, NVIDIA T4 GPU）
- **Fleet 模式**：ON_DEMAND（按需启动，无用户时不计费）
- **最大会话时长**：2 小时（可调整）
- **空闲断开**：10 分钟无操作自动断开

---

## 成本估算（ap-southeast-1 新加坡）

| 资源 | 单价 | 说明 |
|------|------|------|
| stream.graphics.g4dn.xlarge | ~$1.06/小时 | 用户会话期间计费 |
| Image Builder | ~$1.06/小时 | 仅制作镜像时计费，完成后删除 |
| NAT Gateway | ~$0.059/小时 + 数据费 | 持续运行 |
| S3 安装包存储 | < $0.01/月 | 忽略不计 |

---

## 清理资源

```bash
# 停止 Fleet
aws appstream stop-fleet --name siemens-demo-fleet --region ap-southeast-1

# 删除 Stack 和 Fleet 关联
aws appstream disassociate-fleet \
  --fleet-name siemens-demo-fleet \
  --stack-name siemens-demo-stack \
  --region ap-southeast-1

# 删除 Stack 和 Fleet
aws appstream delete-stack --name siemens-demo-stack --region ap-southeast-1
aws appstream delete-fleet --name siemens-demo-fleet --region ap-southeast-1

# 删除自定义镜像
aws appstream delete-image --name siemens-demo-custom-image-v1 --region ap-southeast-1

# 删除 CloudFormation Stack（会删除 VPC、S3 等）
aws cloudformation delete-stack --stack-name siemens-demo --region ap-southeast-1
```

---

*生成时间：2026-04-08 | 区域：ap-southeast-1（新加坡）*
