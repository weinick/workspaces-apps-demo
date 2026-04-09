# Amazon WorkSpaces Applications 通用部署方案

AWS WorkSpaces Applications (AppStream 2.0) 的一键部署工具，支持多 Fleet、多镜像、多客户场景。

---

## 文件结构

```
├── cfn-workspaces-apps-demo.yaml   # CloudFormation 模板（VPC + Image Builder 基础设施）
└── scripts/
    ├── imagebuilder-setup.sh       # 生成 Image Builder 登录 URL + S3 Presigned URL
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
    └── Image Builder（制作自定义镜像）

fleet-stack-deploy.sh（可多次执行，支持多 Fleet）
    ├── Fleet A（非 GPU）── Stack A  →  generate-urls.sh
    └── Fleet B（GPU）── Stack B    →  generate-urls.sh
```

**设计原则：**
- CFN 只管基础设施，Fleet/Stack 通过脚本创建，支持灵活组合
- 多个 Fleet 共用同一套 VPC/网络资源，通过 `fleet-suffix` 区分
- 每个 Fleet 可独立设置实例类型、镜像、Fleet 类型

---

## 部署流程

### Step 1：部署 CloudFormation（基础设施）

```bash
aws cloudformation deploy \
  --template-file cfn-workspaces-apps-demo.yaml \
  --stack-name <env-name> \
  --region <region> \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName=<env-name> \
    InstallerBucketName=<bucket-name> \
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

---

### Step 3：制作自定义镜像

```bash
# 生成 Image Builder 登录 URL
bash scripts/imagebuilder-setup.sh <region> <env-name>
```

登录 Image Builder Windows 桌面后：
1. 安装所需软件
2. 双击桌面 **Image Assistant** → Add App → 填写镜像名称 → Create Image

镜像制作约 20-30 分钟，查看状态：
```bash
aws appstream describe-images \
  --names <image-name> \
  --region <region> \
  --query 'Images[0].State'
```

---

### Step 4：创建 Fleet + Stack

```bash
bash scripts/fleet-stack-deploy.sh \
  <region> \
  <env-name> \
  <image-name> \
  <fleet-suffix> \
  <min-capacity> \
  <max-capacity> \
  <instance-type> \
  <fleet-type>
```

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

## 多 Fleet 场景示例

同一客户有两类培训软件，一类不需要 GPU，一类需要 GPU：

```bash
# Fleet 1：通用软件（无 GPU，成本低）
bash scripts/fleet-stack-deploy.sh \
  ap-southeast-1 my-demo standard-image-v1 standard \
  2 30 stream.standard.xlarge ON_DEMAND

# Fleet 2：AI/图形软件（GPU）
bash scripts/fleet-stack-deploy.sh \
  ap-southeast-1 my-demo gpu-image-v1 gpu \
  2 30 stream.graphics.g4dn.xlarge ON_DEMAND

# 分别预热
ENV_NAME=my-demo-standard bash scripts/scale-fleet.sh warmup 30
ENV_NAME=my-demo-gpu      bash scripts/scale-fleet.sh warmup 20

# 分别生成 URL
bash scripts/generate-urls.sh ap-southeast-1 my-demo-standard 30 3
bash scripts/generate-urls.sh ap-southeast-1 my-demo-gpu      20 3

# 分别归零
ENV_NAME=my-demo-standard bash scripts/scale-fleet.sh down
ENV_NAME=my-demo-gpu      bash scripts/scale-fleet.sh down
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
