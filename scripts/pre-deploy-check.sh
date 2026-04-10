#!/bin/bash
# pre-deploy-check.sh
# 部署前检查脚本：验证目标 region 的所有必备条件
# 包括: Base Image 可用性、Service Quota、IAM 权限、VPC 限制等
# 建议在执行 CloudFormation 部署前运行此脚本

set -euo pipefail

REGION="${1:-ap-southeast-1}"
INSTANCE_TYPE="${2:-stream.graphics.g4dn.xlarge}"
REQUIRED_FLEET_CAPACITY="${3:-2}"   # 计划部署的最大 Fleet 实例数

PASS=0
WARN=0
FAIL=0

# ============================================================
# 工具函数
# ============================================================
pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
section() { echo ""; echo "── $1 ──────────────────────────────────"; }

# 从实例类型提取系列（用于匹配 Base Image）
get_image_family() {
  local instance_type="$1"
  if [[ "$instance_type" == stream.graphics.g4dn.* ]]; then echo "G4dn"
  elif [[ "$instance_type" == stream.graphics.g5.* ]]; then echo "G5"
  elif [[ "$instance_type" == stream.graphics.g6.* ]]; then echo "G6"
  elif [[ "$instance_type" == stream.standard.* ]]; then echo "Standard"
  elif [[ "$instance_type" == stream.compute.* ]]; then echo "Compute"
  elif [[ "$instance_type" == stream.memory.* ]]; then echo "Memory"
  else echo "Unknown"
  fi
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   WorkSpaces Applications 部署前检查                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Region:          $REGION"
echo "  实例类型:        $INSTANCE_TYPE"
echo "  计划 Fleet 容量: $REQUIRED_FLEET_CAPACITY"

# ============================================================
# 1. AWS 凭证和权限检查
# ============================================================
section "1. AWS 凭证 & 基础权限"

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text --region "$REGION" 2>/dev/null || echo "")
if [[ -n "$ACCOUNT_ID" ]]; then
  CALLER=$(aws sts get-caller-identity --query 'Arn' --output text --region "$REGION" 2>/dev/null)
  pass "AWS 凭证有效 (Account: $ACCOUNT_ID)"
  echo "     Identity: $CALLER"
else
  fail "AWS 凭证无效或无权限，请检查 AWS 配置"
  echo ""
  echo "检查完成（凭证异常，无法继续）"
  exit 1
fi

# 检查 AppStream 基础权限（describe-fleets 不支持 --max-results，直接调用）
if aws appstream describe-fleets --region "$REGION" > /dev/null 2>&1; then
  pass "AppStream 读取权限正常"
else
  fail "缺少 AppStream 权限 (appstream:DescribeFleets)"
fi

# 检查 CloudFormation 权限
aws cloudformation list-stacks --region "$REGION" --max-items 1 > /dev/null 2>&1 && \
  pass "CloudFormation 权限正常" || \
  fail "缺少 CloudFormation 权限"

# ============================================================
# 2. Base Image 可用性
# ============================================================
section "2. Base Image 可用性"

IMAGE_FAMILY=$(get_image_family "$INSTANCE_TYPE")
echo "  实例系列: $IMAGE_FAMILY"
echo ""

if [[ "$IMAGE_FAMILY" == "Unknown" ]]; then
  warn "无法识别实例类型系列，请手动查询 Base Image"
else
  # 查询对应系列的公共 Base Image
  if [[ "$IMAGE_FAMILY" == "Standard" || "$IMAGE_FAMILY" == "Compute" || "$IMAGE_FAMILY" == "Memory" ]]; then
    QUERY_FILTER="AppStream-WinServer"
  else
    QUERY_FILTER="AppStream-Graphics-${IMAGE_FAMILY}"
  fi

  echo "  查询 ${IMAGE_FAMILY} 系列 Base Image（Windows）..."
  IMAGES=$(aws appstream describe-images \
    --type PUBLIC \
    --region "$REGION" \
    --query "Images[?contains(Name, '${QUERY_FILTER}') && State=='AVAILABLE'].{Name:Name,CreatedTime:CreatedTime}" \
    --output json 2>/dev/null || echo "[]")

  IMAGE_COUNT=$(echo "$IMAGES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "$IMAGE_COUNT" -gt 0 ]]; then
    pass "${IMAGE_FAMILY} 系列 Base Image 可用（共 ${IMAGE_COUNT} 个）"
    echo ""
    echo "  可用 Base Image 列表（按时间倒序，建议使用最新版本）："
    echo "$IMAGES" | python3 -c "
import sys, json
images = json.load(sys.stdin)
images.sort(key=lambda x: x.get('CreatedTime',''), reverse=True)
for i, img in enumerate(images[:5]):
    marker = '★' if i == 0 else ' '
    print(f'  {marker} {img[\"Name\"]}')
if len(images) > 5:
    print(f'    ... 还有 {len(images)-5} 个旧版本')
"
    echo ""
    RECOMMENDED_IMAGE=$(echo "$IMAGES" | python3 -c "
import sys, json
images = json.load(sys.stdin)
images.sort(key=lambda x: x.get('CreatedTime',''), reverse=True)
print(images[0]['Name']) if images else print('')
" 2>/dev/null)
    echo "  📋 推荐使用: $RECOMMENDED_IMAGE"
  else
    fail "${IMAGE_FAMILY} 系列 Base Image 在 ${REGION} 不可用"
    echo "     请检查该 region 是否支持此实例系列"
  fi
fi

# ============================================================
# 3. Service Quota 检查
# ============================================================
section "3. Service Quota 检查"

# AppStream Quota 检查（通过 service-quotas）
echo "  检查 AppStream 实例 Quota..."

# 尝试获取 AppStream fleet 相关 quota
QUOTA_RESULT=$(aws service-quotas list-service-quotas \
  --service-code appstream \
  --region "$REGION" \
  --query 'Quotas[?contains(QuotaName, `fleet`) || contains(QuotaName, `Fleet`)].{Name:QuotaName,Value:Value}' \
  --output json 2>/dev/null || echo "[]")

QUOTA_COUNT=$(echo "$QUOTA_RESULT" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$QUOTA_COUNT" -gt 0 ]]; then
  pass "AppStream Quota 查询成功"
  echo "$QUOTA_RESULT" | python3 -c "
import sys, json
quotas = json.load(sys.stdin)
for q in quotas:
    print(f'     {q[\"Name\"]}: {int(q[\"Value\"])}')
" 2>/dev/null
else
  warn "无法通过 Service Quotas API 查询 AppStream Quota（部分 region 不支持）"
  echo "     请在 AWS 控制台手动确认: Service Quotas → AppStream"
fi

# 检查 EC2 GPU 实例 Quota（AppStream 底层使用 EC2）
if [[ "$IMAGE_FAMILY" == "G4dn" ]]; then
  VCPU_QUOTA=$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --region "$REGION" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")
  if [[ "$VCPU_QUOTA" != "unknown" ]]; then
    # g4dn.xlarge = 4 vCPU
    REQUIRED_VCPU=$((REQUIRED_FLEET_CAPACITY * 4))
    if python3 -c "exit(0 if float('$VCPU_QUOTA') >= $REQUIRED_VCPU else 1)" 2>/dev/null; then
      pass "EC2 G 系列 vCPU Quota 满足需求 (当前: ${VCPU_QUOTA}, 需要: ${REQUIRED_VCPU})"
    else
      warn "EC2 G 系列 vCPU Quota 可能不足 (当前: ${VCPU_QUOTA}, 需要: ${REQUIRED_VCPU})"
      echo "     请申请提升: aws service-quotas request-service-quota-increase \\"
      echo "       --service-code ec2 --quota-code L-DB2E81BA --desired-value $((REQUIRED_VCPU * 2)) --region $REGION"
    fi
  else
    warn "无法查询 EC2 GPU vCPU Quota，请手动确认"
  fi
fi

# ============================================================
# 4. 网络环境检查
# ============================================================
section "4. 网络环境"

# 检查 VPC 限制（默认每 region 5个 VPC）
VPC_COUNT=$(aws ec2 describe-vpcs --region "$REGION" \
  --query 'length(Vpcs)' --output text 2>/dev/null || echo "unknown")
VPC_QUOTA=$(aws service-quotas get-service-quota \
  --service-code vpc --quota-code L-F678F1CE \
  --region "$REGION" \
  --query 'Quota.Value' --output text 2>/dev/null || echo "5")

if [[ "$VPC_COUNT" != "unknown" ]]; then
  VPC_REMAINING=$((${VPC_QUOTA%.*} - ${VPC_COUNT%.*}))
  if [[ $VPC_REMAINING -gt 0 ]]; then
    pass "VPC 配额充足 (已用: ${VPC_COUNT}, 上限: ${VPC_QUOTA%.*}, 剩余: ${VPC_REMAINING})"
  else
    fail "VPC 配额已满 (已用: ${VPC_COUNT}/${VPC_QUOTA%.*})，无法创建新 VPC"
    echo "     请删除未使用的 VPC 或申请提升配额"
  fi
fi

# 检查 EIP 限制（NAT Gateway 需要一个 EIP）
EIP_COUNT=$(aws ec2 describe-addresses --region "$REGION" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo "unknown")
EIP_QUOTA=$(aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-0263D0A3 \
  --region "$REGION" \
  --query 'Quota.Value' --output text 2>/dev/null || echo "5")

if [[ "$EIP_COUNT" != "unknown" ]]; then
  EIP_REMAINING=$((${EIP_QUOTA%.*} - ${EIP_COUNT%.*}))
  if [[ $EIP_REMAINING -gt 0 ]]; then
    pass "EIP 配额充足 (已用: ${EIP_COUNT}, 上限: ${EIP_QUOTA%.*}, 剩余: ${EIP_REMAINING})"
  else
    fail "EIP 配额已满 (已用: ${EIP_COUNT}/${EIP_QUOTA%.*})，NAT Gateway 需要 1 个 EIP"
  fi
fi

# ============================================================
# 5. 汇总 & 推荐部署命令
# ============================================================
section "检查汇总"

echo ""
echo "  通过: $PASS  警告: $WARN  失败: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo "  ❌ 存在 $FAIL 个必须解决的问题，请修复后再部署"
elif [[ $WARN -gt 0 ]]; then
  echo "  ⚠️  存在 $WARN 个警告，建议确认后再部署"
else
  echo "  ✅ 所有检查通过，可以开始部署"
fi

if [[ -n "${RECOMMENDED_IMAGE:-}" && $FAIL -eq 0 ]]; then
  echo ""
  echo "  📋 推荐 CloudFormation 部署命令："
  echo ""
  echo "  aws cloudformation deploy \\"
  echo "    --template-file cfn-workspaces-apps-demo.yaml \\"
  echo "    --stack-name <stack-name> \\"
  echo "    --region $REGION \\"
  echo "    --capabilities CAPABILITY_NAMED_IAM \\"
  echo "    --parameter-overrides \\"
  echo "      ResourcePrefix=<prefix> \\"
  echo "      ImageBuilderInstanceType=$INSTANCE_TYPE \\"
  echo "      BaseImageName=$RECOMMENDED_IMAGE"
fi

echo ""
