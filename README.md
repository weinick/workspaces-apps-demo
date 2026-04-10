# Amazon WorkSpaces Applications 通用部署方案

AWS WorkSpaces Applications (AppStream 2.0) 的一键部署工具，支持多 Fleet、多镜像、多客户场景。

---

## 前置条件

### 1. 安装 AWS CLI v2

| 平台 | 安装方式 |
|------|----------|
| macOS | [官方文档](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions) 或 `brew install awscli` |
| Linux | [官方文档](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions) |
| Windows | [官方文档](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions) 或 `winget install Amazon.AWSCLI` |

验证安装：
```bash
aws --version
# 输出示例: aws-cli/2.x.x Python/3.x.x ...
```

### 2. 配置 AWS 凭证

```bash
aws configure
# 填入：
#   AWS Access Key ID
#   AWS Secret Access Key
#   Default region（如 ap-southeast-1）
#   Default output format（建议 json）
```

> 💡 如果在 EC2 上运行，绑定了 IAM Role 则无需 `aws configure`，直接使用即可。
>
> 所需最小权限：`appstream:*`、`cloudformation:*`、`s3:*`、`ec2:Describe*`、`iam:*`（用于 CFN 创建 IAM Role）

---

## 文件结构

```
├── cfn-workspaces-apps-demo.yaml   # CloudFormation 模板（VPC + Image Builder 基础设施）
└── scripts/
    ├── pre-deploy-check.sh         # 部署前检查（Base Image、Quota、VPC 等）
    ├── imagebuilder-setup.sh       # 生成 Image Builder 登录 URL + S3 Presigned URL
    ├── create-imagebuilder.sh      # 创建额外的 Image Builder（多实例系列场景）
    ├── fleet-stack-deploy.sh       # 创建 Fleet + Stack + Auto Scaling（支持多 Fleet）
    ├── scale-fleet.sh              # Fleet 预热 / 扩缩容 / 归零
    ├── generate-urls.sh            # 批量生成学员 Streaming URL
    └── cleanup.sh                  # 清理资源
```

---

## 架构说明

```
CloudFormation（一次部署）
    └── VPC + 子网 + NAT Gateway
    └── Security Groups
    └── S3 Bucket（软件安装包）
    └── IAM Role
    └── Image Builder 主（GPU 系列，制作 GPU 镜像）

create-imagebuilder.sh（按需执行，创建额外 Image Builder）
    └── Image Builder 副（Standard 系列，制作非 GPU 镜像）

fleet-stack-deploy.sh（可多次执行，支持多 Fleet）
    ├── Fleet A（非 GPU）── Stack A  →  generate-urls.sh
    └── Fleet B（GPU）── Stack B    →  generate-urls.sh
```

**设计原则：**
- CFN 只管基础设施，Fleet/Stack 通过脚本创建，支持灵活组合
- 多个 Fleet 共用同一套 VPC/网络资源，通过 `fleet-suffix` 区分
- 每个 Fleet 可独立设置实例类型、镜像、Fleet 类型
- **镜像兼容性**：镜像必须与 Fleet 实例系列匹配（G4dn 镜像用于 G4dn Fleet，G5 镜像用于 G5 Fleet）。GPU 镜像可用于 Standard Fleet（GPU 驱动被忽略），但**不同 GPU 系列之间不可混用**（驱动不兼容）

---

## 部署流程

### Step 0：部署前检查

```bash
bash scripts/pre-deploy-check.sh <region> <instance-type> <fleet-capacity>
# 示例
bash scripts/pre-deploy-check.sh ap-southeast-1 stream.graphics.g4dn.xlarge 20
```

自动检查 Base Image 可用性、Service Quota、VPC/EIP 配额，并输出推荐的 CFN 部署命令。

#### 查询可用的 ImageBuilderInstanceType 和 BaseImageName

`pre-deploy-check.sh` 会自动列出目标 region 中该实例系列的所有可用 Base Image，并推荐最新版本。如需手动查询：

```bash
# 查询 Standard 系列可用 Base Image
aws appstream describe-images --type PUBLIC --region <region> \
  --query "Images[?contains(Name,'AppStream-WinServer') && State=='AVAILABLE'].Name" \
  --output table

# 查询 G4dn 系列可用 Base Image
aws appstream describe-images --type PUBLIC --region <region> \
  --query "Images[?contains(Name,'AppStream-Graphics-G4dn') && State=='AVAILABLE'].Name" \
  --output table

# 查询 G5 系列
aws appstream describe-images --type PUBLIC --region <region> \
  --query "Images[?contains(Name,'AppStream-Graphics-G5') && State=='AVAILABLE'].Name" \
  --output table
```

`ImageBuilderInstanceType` 支持的实例类型参考 `fleet-stack-deploy.sh --help` 或 CFN 模板中的 `AllowedValues` 列表。

---

### Step 1：部署 CloudFormation（基础设施）

```bash
aws cloudformation deploy \
  --template-file cfn-workspaces-apps-demo.yaml \
  --stack-name <env-name> \
  --region <region> \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ResourcePrefix=<prefix> \
    ImageBuilderInstanceType=stream.graphics.g4dn.xlarge \
    BaseImageName=AppStream-Graphics-G4dn-WinServer2022-11-10-2025
```

部署约 10-15 分钟，完成后会创建：VPC、子网、NAT Gateway、S3 Bucket、Image Builder。

---

### Step 2：上传软件安装包到 S3

```bash
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name <env-name> --region <region> \
  --query 'Stacks[0].Outputs[?OutputKey==`InstallerBucketName`].OutputValue' \
  --output text)

aws s3 cp <installer.exe> s3://$BUCKET/installers/ --region <region>
```

> ⚠️  **必须上传到 `installers/` 子目录**，不能直接放在 Bucket 根目录。
> `imagebuilder-setup.sh` 会自动检测根目录文件并提示移动，也可提前手动放到正确路径。

---

### Step 3：制作自定义镜像

#### 单一实例系列（只有一种 Fleet 类型）

```bash
# 基本用法（输出所有安装包的 Presigned URL）
bash scripts/imagebuilder-setup.sh <region> <stack-name>

# 可选传入 installer-filter，只输出匹配的安装包 URL（大小写不敏感包含匹配）
bash scripts/imagebuilder-setup.sh <region> <stack-name> <presign-ttl-seconds> <installer-filter>
```

#### 多实例系列（同时有 GPU 和非 GPU Fleet）

CFN 只创建了一个 Image Builder（主，如 G4dn），需要用脚本额外创建其他类型的 Image Builder：

```bash
# 创建额外的 Image Builder
# <builder-suffix> 自由命名，建议反映用途或实例系列，如 standard / mendix / training
bash scripts/create-imagebuilder.sh <region> <stack-name> <builder-suffix> \
  <instance-type> \
  <base-image-name>

# 示例：为第二款软件创建一个 Standard Image Builder
bash scripts/create-imagebuilder.sh <region> <stack-name> <builder-suffix> \
  <instance-type> \
  <base-image-name>

# 分别为各 Image Builder 生成登录 URL（用 installer-filter 只显示对应安装包）
bash scripts/imagebuilder-setup.sh <region> <stack-name> <presign-ttl-seconds> <installer-filter-1>  # Image Builder 1
bash scripts/imagebuilder-setup.sh <region> <stack-name> <presign-ttl-seconds> <installer-filter-2>  # Image Builder 2
```

> **镜像兼容性**：镜像须与 Fleet 实例系列匹配（G4dn↔G4dn，G5↔G5）。GPU 镜像可用于 Standard Fleet（GPU 驱动被忽略），但不同 GPU 系列之间驱动不兼容，不可混用。

登录 Image Builder Windows 桌面后：
1. 安装所需软件
2. 双击桌面 **Image Assistant** → Add App → 填写镜像名称 → Create Image

镜像制作约 20-30 分钟，查看状态：
```bash
aws appstream describe-images \
  --names <image-name> \
  --region <region> \
  --query 'Images[0].State' \
  --output text
```

镜像状态说明：

| 状态 | 含义 |
|------|------|
| `PENDING` | 排队等待制作 |
| `SNAPSHOTTING` | 正在打包镜像（主要耗时阶段） |
| `AVAILABLE` | ✅ 镜像制作完成，可以创建 Fleet |
| `FAILED` | ❌ 制作失败，查看 Image Builder 日志排查 |

**制作多个镜像（串行）：**

一个 Image Builder 做完一个镜像后会自动关机，然后自动重启恢复到干净状态，可以继续制作下一个。等 Image Builder 回到 `RUNNING` 状态后重新运行脚本：

```bash
# 查看 Image Builder 状态
aws appstream describe-image-builders \
  --names <builder-name> \
  --region <region> \
  --query 'ImageBuilders[0].State' \
  --output text

# Image Builder RUNNING 后，生成下一个镜像的登录 URL
bash scripts/imagebuilder-setup.sh <region> <env-name> 7200 <installer-filter>
```

> 💡 完成所有镜像制作后，立即删除 Image Builder 停止计费：
> ```bash
> bash scripts/delete-imagebuilder.sh <region> <env-name>
> ```

---

### Step 4：创建 Fleet + Stack

```bash
bash scripts/fleet-stack-deploy.sh \
  <region> \
  <cfn-stack-name> \
  <image-name> \
  <fleet-suffix> \
  <min-capacity> \
  <max-capacity> \
  <instance-type> \
  [fleet-type]
```

**参数说明：**

| 参数 | 必填 | 说明 | 示例 |
|------|------|------|------|
| `region` | ✅ | AWS 区域 | `ap-southeast-1` |
| `cfn-stack-name` | ✅ | CFN Stack 名称，用于读取 VPC/SG 等网络配置 | `my-demo` |
| `image-name` | ✅ | 自定义镜像名称（Image Assistant 制作完成后的名称） | `my-demo-gpu-image-v1` |
| `fleet-suffix` | ✅ | Fleet 标识后缀，自由命名，用于区分多个 Fleet | `gpu` / `mendix` |
| `min-capacity` | 可选 | 最小实例数，默认 2 | `1` |
| `max-capacity` | 可选 | Auto Scaling 上限，默认 20 | `10` |
| `instance-type` | ✅ | 实例类型，须与镜像系列匹配 | `stream.graphics.g4dn.xlarge` |
| `fleet-type` | 可选 | Fleet 类型，默认 ON_DEMAND | `ON_DEMAND` |

**实例类型参考：**

| 系列 | 实例类型 | 适用场景 |
|------|---------|---------|
| 通用 | `stream.standard.medium/large/xlarge/2xlarge` | 办公、浏览器、轻量应用 |
| 计算优化 | `stream.compute.large/.../8xlarge` | 高 CPU 计算 |
| 内存优化 | `stream.memory.large/.../8xlarge` | 大内存数据集 |
| GPU G4dn | `stream.graphics.g4dn.xlarge/.../16xlarge` (NVIDIA T4) | AI 推理、图形软件 |
| GPU G5 | `stream.graphics.g5.xlarge/.../48xlarge` (NVIDIA A10G) | 高端图形、视频渲染 |
| GPU G6 | `stream.graphics.g6.xlarge/.../48xlarge` (NVIDIA L4) | 新一代 GPU，性价比高 |

**Fleet 类型说明：**

| 类型 | 计费方式 | 启动延迟 | 适用场景 |
|------|----------|----------|----------|
| `ON_DEMAND` | 用户连接时按运行实例收费，空闲时收极小的 stopped 费用 | 1-2 分钟 | 培训、演示、非实时场景 |
| `ALWAYS_ON` | 实例持续运行，无论是否有用户均按全价计费 | 即时 | 企业生产环境、要求零等待 |
| `ELASTIC` | 仅 streaming 会话期间计费（按秒，最低 15 分钟），需使用 App Block | 较长（含下载） | 低频使用、轻量应用 |

---

### Step 5：预热实例（培训前）

```bash
# 预热并等待所有实例就绪
ENV_NAME=<env-name>-<fleet-suffix> bash scripts/scale-fleet.sh warmup <count>

# 查看状态
ENV_NAME=<env-name>-<fleet-suffix> bash scripts/scale-fleet.sh status
```

---

### Step 6：生成 Streaming URL

```bash
bash scripts/generate-urls.sh <region> <env-name>-<fleet-suffix> <user-count> <validity-hours>
```

---

### Step 7：培训结束归零

```bash
ENV_NAME=<env-name>-<fleet-suffix> bash scripts/scale-fleet.sh down
```

---

## 多 Fleet 场景示例（GPU + 非 GPU）

以下示例中，`<builder-suffix>` 和 `<fleet-suffix>` 均为自由命名，建议使用能反映用途的词（如 `gpu`、`mendix`、`training-a`）。

```bash
# Step 1: 部署前检查（两种实例类型分别检查）
bash scripts/pre-deploy-check.sh ap-southeast-1 stream.graphics.g4dn.xlarge 20
bash scripts/pre-deploy-check.sh ap-southeast-1 stream.standard.xlarge 30

# Step 2: 部署 CFN（主 Image Builder 用 G4dn）
aws cloudformation deploy ...

# Step 3: 额外创建 Image Builder（用于非 GPU 软件，builder-suffix 自定义）
# 可用 Base Image 通过 pre-deploy-check.sh 查询（见 Step 0）
bash scripts/create-imagebuilder.sh ap-southeast-1 my-demo mendix \
  stream.standard.xlarge <base-image-name>

# Step 4: 分别为各 Image Builder 制作镜像（installer-filter 按安装包关键字过滤）
bash scripts/imagebuilder-setup.sh ap-southeast-1 my-demo 7200 <gpu-software-keyword>     # GPU 镜像
bash scripts/imagebuilder-setup.sh ap-southeast-1 my-demo 7200 <standard-software-keyword> # 非 GPU 镜像

# Step 5: 创建两个 Fleet（image-name 为 Image Assistant 制作时填写的镜像名）
# Fleet 1：通用软件（无 GPU，成本低）
bash scripts/fleet-stack-deploy.sh \
  ap-southeast-1 my-demo <mendix-image-name> mendix \
  2 30 stream.standard.xlarge

# Fleet 2：AI/图形软件（GPU）
bash scripts/fleet-stack-deploy.sh \
  ap-southeast-1 my-demo <gpu-image-name> gpu \
  2 30 stream.graphics.g4dn.xlarge

# 分别预热
ENV_NAME=my-demo-mendix bash scripts/scale-fleet.sh warmup 30
ENV_NAME=my-demo-gpu    bash scripts/scale-fleet.sh warmup 20

# 分别生成 URL
bash scripts/generate-urls.sh ap-southeast-1 my-demo-mendix 30 3
bash scripts/generate-urls.sh ap-southeast-1 my-demo-gpu    20 3

# 分别归零
ENV_NAME=my-demo-mendix bash scripts/scale-fleet.sh down
ENV_NAME=my-demo-gpu    bash scripts/scale-fleet.sh down
```

---

## 成本估算参考（ap-southeast-1）

| 实例类型 | 运行费 | Stopped 费 | 适用软件 |
|----------|--------|------------|----------|
| stream.standard.xlarge | ~$0.30/hr | $0.025/hr | 办公/浏览器/轻量 IDE |
| stream.graphics.g4dn.xlarge | ~$1.45/hr | $0.025/hr | AI Studio、图形软件 |

> ON_DEMAND 模式下，无用户连接时仅收 $0.025/hr/实例（所有实例类型统一价）

---

## 清理资源

```bash
bash scripts/cleanup.sh <region> <env-name> <fleet-suffix>

# 完整清理 CFN 基础设施（删除 VPC、S3 等）
aws cloudformation delete-stack --stack-name <env-name> --region <region>
```
