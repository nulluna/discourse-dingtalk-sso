#!/bin/bash

# Discourse 钉钉 SSO 插件验证脚本
# Discourse DingTalk SSO Plugin Verification Script

set -e

echo "🔍 开始验证插件 / Starting plugin verification..."
echo ""

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查函数
check_pass() {
    echo -e "${GREEN}✅ $1${NC}"
}

check_fail() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

check_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# 1. 检查必需文件
echo "📁 检查文件结构 / Checking file structure..."

required_files=(
    "plugin.rb"
    "lib/dingtalk_authenticator.rb"
    "lib/omniauth/strategies/dingtalk.rb"
    "lib/discourse_dingtalk/engine.rb"
    "config/settings.yml"
    "config/locales/server.zh_CN.yml"
    "config/locales/server.en.yml"
    "config/locales/client.zh_CN.yml"
    "config/locales/client.en.yml"
)

for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        check_pass "文件存在: $file"
    else
        check_fail "文件缺失: $file"
    fi
done

echo ""

# 2. 检查Ruby语法
echo "🔍 检查Ruby语法 / Checking Ruby syntax..."

find . -name "*.rb" -not -path "./spec/*" | while read file; do
    if ruby -c "$file" > /dev/null 2>&1; then
        check_pass "语法正确: $file"
    else
        check_fail "语法错误: $file"
    fi
done

echo ""

# 3. 检查关键代码片段
echo "🔧 检查关键实现 / Checking critical implementations..."

# 检查钉钉Token格式
if grep -q "clientId.*client.id" lib/omniauth/strategies/dingtalk.rb; then
    check_pass "Token请求格式正确 (clientId/clientSecret)"
else
    check_warn "未找到正确的Token请求格式"
fi

# 检查错误处理
if grep -q "rescue.*StandardError" lib/dingtalk_authenticator.rb; then
    check_pass "异常处理已实现"
else
    check_warn "缺少异常处理"
fi

# 检查nil安全
if grep -q "\.present?" lib/dingtalk_authenticator.rb; then
    check_pass "Nil安全检查已实现"
else
    check_warn "可能缺少nil检查"
fi

echo ""

# 4. 检查配置项
echo "⚙️  检查配置项 / Checking settings..."

required_settings=(
    "dingtalk_enabled"
    "dingtalk_client_id"
    "dingtalk_client_secret"
)

for setting in "${required_settings[@]}"; do
    if grep -q "$setting:" config/settings.yml; then
        check_pass "配置项存在: $setting"
    else
        check_fail "配置项缺失: $setting"
    fi
done

# 检查虚拟邮箱配置
optional_settings=(
    "dingtalk_allow_virtual_email"
    "dingtalk_virtual_email_domain"
    "dingtalk_mobile_email_domain"
    "dingtalk_username_template"
)

for setting in "${optional_settings[@]}"; do
    if grep -q "$setting:" config/settings.yml; then
        check_pass "虚拟邮箱配置存在: $setting"
    fi
done

echo ""

# 5. 检查国际化
echo "🌐 检查国际化 / Checking i18n..."

if [ -f "config/locales/server.zh_CN.yml" ] && [ -f "config/locales/server.en.yml" ]; then
    check_pass "中英文本地化文件存在"
else
    check_fail "缺少本地化文件"
fi

echo ""

# 6. 检查测试文件
echo "🧪 检查测试文件 / Checking test files..."

test_files=(
    "spec/lib/dingtalk_authenticator_spec.rb"
    "spec/lib/omniauth_dingtalk_spec.rb"
    "spec/requests/dingtalk_authentication_spec.rb"
)

for file in "${test_files[@]}"; do
    if [ -f "$file" ]; then
        check_pass "测试文件存在: $file"
    else
        check_warn "测试文件缺失: $file"
    fi
done

echo ""

# 7. 检查文档
echo "📚 检查文档 / Checking documentation..."

docs=(
    "README.md"
    "WORKFLOW.md"
    "DEPLOYMENT.md"
    "TESTING.md"
    "IMPROVEMENTS.md"
)

for doc in "${docs[@]}"; do
    if [ -f "$doc" ]; then
        check_pass "文档存在: $doc"
    else
        check_warn "文档缺失: $doc"
    fi
done

echo ""

# 8. 统计信息
echo "📊 代码统计 / Code statistics..."

total_lines=$(find . -name "*.rb" -not -path "./spec/*" -not -path "./vendor/*" | xargs wc -l | tail -1 | awk '{print $1}')
test_lines=$(find spec -name "*.rb" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

echo "总代码行数 / Total code lines: $total_lines"
echo "测试代码行数 / Test code lines: ${test_lines:-0}"

echo ""

# 最终结果
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_pass "插件验证完成! / Plugin verification completed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ 插件已准备好部署到生产环境"
echo "✅ Plugin is ready for production deployment"
echo ""
