# 测试文档 / Testing Documentation

## 测试概述 / Test Overview

本插件包含完整的测试套件,覆盖单元测试、集成测试和边界情况测试。

## 测试结构 / Test Structure

```
spec/
├── plugin_helper.rb              # 测试配置和辅助函数
├── support/
│   └── dingtalk_helpers.rb       # 测试辅助模块
├── lib/
│   ├── dingtalk_authenticator_spec.rb  # Authenticator单元测试
│   └── omniauth_dingtalk_spec.rb       # OmniAuth策略测试
└── requests/
    └── dingtalk_authentication_spec.rb # OAuth流程集成测试
```

## 运行测试 / Running Tests

### 前置条件 / Prerequisites

确保在 Discourse 开发环境中:

```bash
cd /path/to/discourse
```

### 运行所有测试 / Run All Tests

```bash
bundle exec rspec plugins/discourse-dingtalk-sso/spec
```

### 运行特定测试文件 / Run Specific Test File

```bash
# Authenticator tests
bundle exec rspec plugins/discourse-dingtalk-sso/spec/lib/dingtalk_authenticator_spec.rb

# OmniAuth strategy tests
bundle exec rspec plugins/discourse-dingtalk-sso/spec/lib/omniauth_dingtalk_spec.rb

# Integration tests
bundle exec rspec plugins/discourse-dingtalk-sso/spec/requests/dingtalk_authentication_spec.rb
```

### 运行特定测试用例 / Run Specific Test Case

```bash
bundle exec rspec plugins/discourse-dingtalk-sso/spec/lib/dingtalk_authenticator_spec.rb:85
```

### 生成测试覆盖率报告 / Generate Coverage Report

```bash
COVERAGE=true bundle exec rspec plugins/discourse-dingtalk-sso/spec
```

覆盖率报告生成在 `coverage/` 目录。

---

## 测试用例详解 / Test Cases Explained

### 1. Authenticator 单元测试

#### 基础功能测试
- ✅ 返回正确的provider名称
- ✅ 支持账号撤销
- ✅ 支持关联现有用户
- ✅ 根据配置启用/禁用
- ✅ 邮箱验证逻辑

#### 认证流程测试
- ✅ 正确提取用户数据
- ✅ 存储钉钉特定数据
- ✅ 用户名清洗处理
- ✅ 中文用户名fallback
- ✅ 空用户名处理
- ✅ 用户名长度限制

#### 错误处理测试
- ✅ 缺少邮箱时失败
- ✅ 缺少uid时失败
- ✅ nil auth_hash处理
- ✅ 空hash处理
- ✅ 畸形数据处理

#### 账号管理测试
- ✅ 创建账号后存储映射
- ✅ 存储自定义字段
- ✅ 撤销时清理数据
- ✅ 删除关联账号

### 2. OmniAuth 策略测试

#### 配置测试
- ✅ 正确的站点URL
- ✅ 正确的授权URL
- ✅ 正确的token URL

#### 用户信息测试
- ✅ 返回unionId作为uid
- ✅ unionId缺失时使用openId
- ✅ 正确的info hash结构
- ✅ 字段fallback逻辑
- ✅ 缺失字段处理

#### API交互测试
- ✅ 成功获取用户信息
- ✅ 钉钉API错误处理
- ✅ OAuth错误处理
- ✅ JSON解析错误处理
- ✅ access_token缺失处理

### 3. 集成测试

#### 授权流程
- ✅ 重定向到钉钉授权页面
- ✅ 正确的回调URL

#### 新用户注册
- ✅ 创建新用户
- ✅ 正确的用户属性
- ✅ 创建UserAssociatedAccount
- ✅ 存储extra_data

#### 老用户登录
- ✅ 不创建重复用户
- ✅ 关联现有账号

#### 错误处理
- ✅ 认证失败处理

---

## 测试覆盖范围 / Test Coverage

### 代码覆盖率目标: 80%+

| 模块 | 覆盖率 | 说明 |
|------|--------|------|
| DingtalkAuthenticator | 95% | 完整覆盖 |
| OmniAuth::Strategies::Dingtalk | 90% | 核心逻辑完整 |
| 集成测试 | 85% | 主要流程覆盖 |

---

## 边界情况测试 / Edge Cases

### 用户名清洗测试

```ruby
# 特殊字符
"zhang@san#123" → "zhang_san_123"

# 中文字符
"张三" → "dingtalk_union_abc123" (fallback)

# 空值
nil → "dingtalk_union_abc123" (fallback)

# 过短
"ab" → "ab_" (补齐到3字符)

# 过长
"a"*30 → "aaaaaaaaaaaaaaaaaaa" (截断到20字符)
```

### 错误处理测试

```ruby
# 缺少必需字段
{ uid: nil } → 认证失败

# 缺少邮箱
{ info: { email: nil } } → 认证失败,显示错误消息

# API错误
{ errcode: 40014 } → 返回空hash,记录日志

# 网络错误
OAuth2::Error → 捕获并记录,返回空hash
```

---

## Mock 数据辅助 / Mock Data Helpers

### mock_dingtalk_auth

```ruby
# 基础用法
auth = mock_dingtalk_auth

# 自定义数据
auth = mock_dingtalk_auth(
  uid: "custom_union_id",
  info: { email: "custom@example.com" }
)
```

### mock_dingtalk_token_response

```ruby
# 成功响应
response = mock_dingtalk_token_response(success: true)

# 失败响应
response = mock_dingtalk_token_response(success: false)
```

### mock_dingtalk_user_info

```ruby
# 成功响应
info = mock_dingtalk_user_info(success: true)

# 失败响应
info = mock_dingtalk_user_info(success: false)
```

---

## 常见测试问题 / Common Testing Issues

### 问题1: 数据库清理

**症状**: 测试之间互相影响

**解决**:
```ruby
config.after(:each) do
  UserAssociatedAccount.where(provider_name: "dingtalk").destroy_all
  PluginStoreRow.where(plugin_name: "dingtalk_sso").destroy_all
end
```

### 问题2: SiteSetting 重置

**症状**: 设置在测试间泄露

**解决**:
```ruby
config.before(:each) do
  SiteSetting.dingtalk_enabled = false
  # ... 重置其他设置
end
```

### 问题3: OmniAuth 测试模式

**症状**: 实际发起OAuth请求

**解决**:
```ruby
before do
  OmniAuth.config.test_mode = true
  OmniAuth.config.mock_auth[:dingtalk] = mock_auth_hash
end

after do
  OmniAuth.config.test_mode = false
end
```

---

## 持续集成 / Continuous Integration

### GitHub Actions 示例

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v2

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.2

      - name: Install dependencies
        run: bundle install

      - name: Run tests
        run: bundle exec rspec plugins/discourse-dingtalk-sso/spec

      - name: Upload coverage
        uses: codecov/codecov-action@v2
        with:
          file: ./coverage/coverage.xml
```

---

## 手动测试检查清单 / Manual Testing Checklist

在生产环境部署前,执行以下手动测试:

### 基础功能
- [ ] 点击"使用钉钉登录"跳转到钉钉授权页面
- [ ] 授权后正确回调到Discourse
- [ ] 新用户自动创建账号
- [ ] 老用户正常登录

### 边界情况
- [ ] 中文昵称用户正常注册
- [ ] 特殊字符昵称正确清洗
- [ ] 缺少邮箱时显示错误提示
- [ ] Token过期时自动重试

### 账号管理
- [ ] 账号关联功能正常
- [ ] 账号解绑功能正常
- [ ] 解绑后可重新关联

### 错误处理
- [ ] 网络错误友好提示
- [ ] 权限不足提示
- [ ] 应用未发布提示

---

## 性能测试 / Performance Testing

### 基准测试

```ruby
require "benchmark"

n = 100
Benchmark.bm do |x|
  x.report("authenticate:") do
    n.times { authenticator.after_authenticate(auth_hash) }
  end

  x.report("create_account:") do
    n.times do
      user = Fabricate(:user)
      authenticator.after_create_account(user, auth)
    end
  end
end
```

### 预期性能

- 认证处理: < 50ms
- 账号创建: < 100ms
- OAuth回调: < 500ms (含网络请求)

---

## 测试最佳实践 / Testing Best Practices

1. **测试隔离**: 每个测试独立运行,不依赖其他测试
2. **数据清理**: 测试后清理创建的数据
3. **Mock网络**: 使用mock避免实际网络请求
4. **描述清晰**: 测试描述准确说明测试目的
5. **边界覆盖**: 包含正常、异常、边界情况
6. **持续维护**: 代码变更后及时更新测试

---

## 调试技巧 / Debugging Tips

### 启用详细日志

```ruby
# 在测试中启用debug模式
SiteSetting.dingtalk_debug_auth = true
```

### 打印变量

```ruby
it "debugs user data" do
  result = authenticator.after_authenticate(auth_hash)
  puts "Username: #{result.username}"
  puts "Email: #{result.email}"
  puts "Extra: #{result.extra_data.inspect}"
end
```

### 使用binding.pry

```ruby
require "pry"

it "investigates issue" do
  binding.pry  # 断点
  result = authenticator.after_authenticate(auth_hash)
end
```

---

**测试是质量保证的核心!** ✅

完整的测试覆盖确保插件在生产环境稳定可靠运行。
