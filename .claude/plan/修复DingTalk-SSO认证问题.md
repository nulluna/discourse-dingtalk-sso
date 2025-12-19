# 修复 DingTalk SSO 认证问题 - 执行计划

## 任务上下文

**任务描述:** 修复 DingTalk SSO 插件的三个核心问题

### 问题列表
1. 没有把 DingTalk Union ID 和 Discourse 用户体系绑定
2. DingTalk 登录已存在的 Discourse 用户还是走到 signup 页面
3. 虚拟邮箱的域名可配置（三种情况）

### 用户确认的实现策略
- ✅ 通过真实邮箱自动匹配已存在用户
- ✅ 虚拟邮箱配置满意（无需调整）
- ✅ 仅修复新用户逻辑（不处理历史数据）

---

## 方案选择

**采用方案:** 方案1 - 最小改动方案

**核心思路:** 依赖 Discourse 核心的邮箱匹配机制，删除冗余代码，优化日志输出。

**设计原则:**
- **KISS**: 利用 Discourse 现有机制，避免重复实现
- **DRY**: 删除 PluginStore 冗余存储
- **YAGNI**: 不实现当前不需要的功能

---

## 问题根因分析

### 问题1: Union ID 绑定
- **现状:** `UserAssociatedAccount` 表已正确存储 Union ID 为 `provider_uid`
- **问题:** `after_create_account` 中的 PluginStore 存储完全冗余
- **修复:** 删除 PluginStore 相关代码

### 问题2: 已存在用户跳转注册页面
- **现状:** Discourse 核心通过邮箱匹配已存在用户的机制已启用
- **问题:** 虚拟邮箱导致邮箱匹配失败
- **修复:** 确认 `generate_email_with_fallback` 优先返回真实邮箱（已实现）

### 问题3: 虚拟邮箱配置
- **现状:** 已完全实现三级降级机制
  1. DingTalk email 直接使用
  2. 无 email 时使用 mobile + 可配置域名
  3. 都无时使用 unionid + 可配置域名
- **修复:** 无需修改

---

## 详细执行步骤

### 步骤1: 删除 `after_create_account` 中的 PluginStore 代码

**文件:** `lib/dingtalk_authenticator.rb:144-161`

**删除内容:**
```ruby
::PluginStore.set(
  "dingtalk_sso",
  "dingtalk_union_id_#{data[:dingtalk_union_id]}",
  { user_id: user.id, created_at: Time.now }
)
```

**原因:** Union ID 已自动存储在 `UserAssociatedAccount.provider_uid`

---

### 步骤2: 删除 `revoke` 方法中的 PluginStore 清理代码

**文件:** `lib/dingtalk_authenticator.rb:163-188`

**删除内容:**
```ruby
extra_data = JSON.parse(authenticator.extra) rescue {}
union_id = extra_data["dingtalk_union_id"]

if union_id.present?
  ::PluginStore.remove("dingtalk_sso", "dingtalk_union_id_#{union_id}")
end
```

**原因:** PluginStore 不再使用，清理代码也无需保留

---

### 步骤3: 增强 `after_authenticate` 日志输出

**文件:** `lib/dingtalk_authenticator.rb:131-135`

**新增内容:**
```ruby
if SiteSetting.dingtalk_debug_auth
  Rails.logger.info "DingTalk auth result: username=#{result.username}, email=#{result.email}, email_valid=#{result.email_valid}, uid=#{auth_token[:uid]}"
  Rails.logger.info "DingTalk auth: will use email matching for existing users" if result.email_valid
end
```

**原因:** 帮助诊断邮箱匹配逻辑

---

### 步骤4: 运行测试验证

**命令:**
```bash
bundle exec rspec plugins/discourse-dingtalk-sso/spec/lib/dingtalk_authenticator_spec.rb
bundle exec rspec plugins/discourse-dingtalk-sso/spec/requests/dingtalk_authentication_spec.rb
```

---

## 预期结果

### 代码改动统计
- 删除: 10 行
- 新增: 2 行
- 修改文件: 1 个

### 功能验证
- ✅ Union ID 正确存储在 `UserAssociatedAccount.provider_uid`
- ✅ 已存在用户通过真实邮箱自动关联
- ✅ 虚拟邮箱三级降级正常工作
- ✅ 所有测试通过

---

## 风险评估

| 风险点 | 概率 | 影响 | 缓解措施 |
|--------|------|------|----------|
| 删除 PluginStore 影响已有功能 | 低 | 低 | PluginStore 数据未被使用 |
| 邮箱匹配逻辑失败 | 低 | 中 | 现有测试覆盖，且逻辑未修改 |
| 测试用例需要调整 | 中 | 低 | 可能需要删除 PluginStore 相关断言 |

---

## 执行时间

**创建时间:** 2025-12-19
**预计执行时间:** 15 分钟
