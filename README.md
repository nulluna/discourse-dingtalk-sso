# Discourse 钉钉 SSO 插件 / DingTalk SSO Plugin

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Discourse](https://img.shields.io/badge/Discourse-2.7.0%2B-blue)](https://www.discourse.org/)

为 Discourse 论坛提供钉钉企业内部应用的单点登录(SSO)集成。

Provides DingTalk Enterprise App Single Sign-On (SSO) integration for Discourse forums.

---

## ✨ 功能特性 / Features

- ✅ 使用钉钉账号快速登录Discourse / Quick login with DingTalk account
- ✅ 自动同步用户信息(姓名/邮箱/手机号) / Auto-sync user info (name/email/phone)
- ✅ 支持账号关联与解绑 / Account association and revocation
- ✅ 完整的中英文界面 / Full Chinese & English interface
- ✅ 符合Discourse最佳实践 / Following Discourse best practices
- ✅ 完整的测试覆盖 / Comprehensive test coverage

---

## 📋 前置条件 / Prerequisites

1. **Discourse 2.7.0 或更高版本** / Discourse 2.7.0 or higher
2. **钉钉企业内部应用** / DingTalk Enterprise Internal App with:
   - ✅ 个人手机号信息权限 / Personal phone number permission
   - ✅ 通讯录个人信息读权限 / Address book personal info read permission

---

## 🚀 安装步骤 / Installation

### 方法一:Docker 容器安装 / Method 1: Docker Container

#### 1. 编辑容器配置 / Edit Container Config

编辑 `containers/app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/nulluna/discourse-dingtalk-sso.git
```

#### 2. 重建容器 / Rebuild Container

```bash
cd /var/discourse
./launcher rebuild app
```

### 方法二:开发环境安装 / Method 2: Development Setup

```bash
cd discourse/plugins
git clone https://github.com/nulluna/discourse-dingtalk-sso.git
bundle install
```

---

## ⚙️ 配置指南 / Configuration Guide

### 步骤1:钉钉开放平台配置 / Step 1: DingTalk Open Platform

#### 1.1 创建企业内部应用 / Create Enterprise App

1. 登录 [钉钉开放平台](https://open-dev.dingtalk.com/)
2. 创建"企业内部应用"
3. 记录 **Client ID** 和 **Client Secret**

#### 1.2 配置回调URL / Configure Callback URL

在应用的 **开发配置 > 安全设置** 中添加:

```
https://your-discourse-domain.com/auth/dingtalk/callback
```

⚠️ **重要**: URL必须精确匹配,包括协议(https)和域名

#### 1.3 开通必需权限 / Enable Required Permissions

在 **开发配置 > 权限管理** 中开通:

- ✅ 个人手机号信息
- ✅ 通讯录个人信息读权限

#### 1.4 发布应用 / Publish App

在 **应用发布 > 版本管理与发布** 中发布应用。

---

### 步骤2:Discourse 管理后台配置 / Step 2: Discourse Admin Config

登录 Discourse 管理后台,进入 **管理 > 设置 > 登录**:

| 配置项 | 说明 | 示例值 |
|--------|------|--------|
| `dingtalk_enabled` | **启用插件** | ✅ 勾选 |
| `dingtalk_client_id` | 钉钉应用Client ID | `dingxxxxxxx` |
| `dingtalk_client_secret` | 钉钉应用Client Secret | `xxxxxxxxxxxxx` |
| `dingtalk_scope` | OAuth授权范围 | `openid` (默认) |
| `dingtalk_button_title` | 登录按钮文本 | `使用钉钉登录` |
| `dingtalk_authorize_signup` | 允许自动注册 | 根据需求勾选 |

---

## 📊 配置参数详解 / Configuration Parameters

| 参数名 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `dingtalk_enabled` | Boolean | `false` | 启用/禁用插件 |
| `dingtalk_client_id` | String | - | **必填** 钉钉应用Client ID |
| `dingtalk_client_secret` | Secret | - | **必填** 钉钉应用Client Secret |
| `dingtalk_authorize_url` | String | `https://login.dingtalk.com/oauth2/auth` | OAuth授权端点 |
| `dingtalk_token_url` | String | `https://api.dingtalk.com/v1.0/oauth2/userAccessToken` | Token获取端点 |
| `dingtalk_user_info_url` | String | `https://api.dingtalk.com/v1.0/contact/users/me` | 用户信息端点 |
| `dingtalk_scope` | String | `openid` | OAuth授权范围 |
| `dingtalk_button_title` | String | `使用钉钉登录` | 登录按钮显示文本 |
| `dingtalk_authorize_signup` | Boolean | `false` | 允许通过钉钉自动注册 |
| `dingtalk_overrides_email` | Boolean | `false` | 允许钉钉邮箱覆盖本地邮箱 |
| `dingtalk_debug_auth` | Boolean | `false` | 启用OAuth调试日志(隐藏) |

---

## 🔄 用户数据映射 / User Data Mapping

| 钉钉字段 | Discourse字段 | 说明 |
|---------|--------------|------|
| `nick` | `username` / `name` | 用户名/显示名称 |
| `email` | `email` | 邮箱地址 |
| `mobile` | `custom_fields["dingtalk_mobile"]` | 手机号(存储在自定义字段) |
| `unionId` | `uid` | 用户唯一标识(企业内唯一) |
| `openId` | `extra_data["dingtalk_open_id"]` | 应用内用户ID |
| `corpId` | `extra_data["dingtalk_corp_id"]` | 企业ID |

---

## 🔍 故障排查 / Troubleshooting

### ❌ 问题1: 重定向URL不匹配
**错误信息**: `redirect_uri mismatch`

**解决方案**:
1. 确保钉钉后台配置的回调URL完全匹配: `https://your-domain.com/auth/dingtalk/callback`
2. 检查是否使用了HTTPS(生产环境必须)
3. 确认域名拼写正确

---

### ❌ 问题2: 无法获取用户邮箱
**错误信息**: `Cannot retrieve email from DingTalk`

**解决方案**:
1. 检查应用是否开通了"通讯录个人信息读权限"
2. 确认用户在钉钉中已设置邮箱
3. 验证企业管理员是否限制了邮箱访问权限

---

### ❌ 问题3: Token获取失败
**错误信息**: `OAuth token error`

**解决方案**:
1. 验证Client ID和Client Secret是否正确
2. 检查应用是否已发布
3. 确认应用状态为"已上线"
4. 启用`dingtalk_debug_auth`查看详细日志

---

### ❌ 问题4: 用户自动创建失败

**解决方案**:
1. 确保`dingtalk_authorize_signup`已启用
2. 检查Discourse的`enable_sso`设置未启用(会冲突)
3. 验证邮箱地址格式正确

---

## 🧪 开发与测试 / Development & Testing

### 运行测试 / Run Tests

```bash
bundle exec rspec plugins/discourse-dingtalk-sso/spec
```

### 代码规范检查 / Linting

```bash
bundle exec rubocop plugins/discourse-dingtalk-sso
```

### 启用调试模式 / Enable Debug Mode

在管理后台启用 `dingtalk_debug_auth`,查看详细OAuth日志:

```ruby
Rails.logger.info "DingTalk auth result: ..."
```

---

## 🔒 安全建议 / Security Recommendations

1. ✅ **必须使用HTTPS** - 生产环境禁止使用HTTP
2. ✅ **保护Client Secret** - 不要提交到版本控制
3. ✅ **精确匹配回调URL** - 避免使用通配符
4. ✅ **定期更新密钥** - 建议每6个月轮换一次
5. ✅ **最小权限原则** - 只申请必需的API权限

---

## 📚 架构设计 / Architecture

### 核心组件 / Core Components

```
lib/
├── omniauth/strategies/dingtalk.rb    # OmniAuth OAuth2策略
├── dingtalk_authenticator.rb          # Discourse认证器
└── discourse_dingtalk/engine.rb       # Rails引擎

config/
├── settings.yml                        # 插件配置项
└── locales/                           # 国际化文本
    ├── server.zh_CN.yml
    ├── server.en.yml
    ├── client.zh_CN.yml
    └── client.en.yml

spec/
├── lib/dingtalk_authenticator_spec.rb
└── requests/dingtalk_authentication_spec.rb
```

### 认证流程 / Authentication Flow

```
用户点击"使用钉钉登录"
    ↓
重定向到钉钉授权页面
    ↓
用户授权后返回code
    ↓
使用code换取access_token
    ↓
使用access_token获取用户信息
    ↓
创建/更新Discourse用户
    ↓
登录成功
```

---

## 🤝 贡献指南 / Contributing

欢迎贡献代码、报告问题或提出建议!

1. Fork 本仓库
2. 创建特性分支: `git checkout -b feature/amazing-feature`
3. 提交更改: `git commit -m 'Add amazing feature'`
4. 推送分支: `git push origin feature/amazing-feature`
5. 提交Pull Request

---

## 📄 许可证 / License

本项目采用 [MIT License](LICENSE) 开源。

---

## 📞 支持与反馈 / Support

- **Issues**: [GitHub Issues](https://github.com/nulluna/discourse-dingtalk-sso/issues)
- **文档**: [WORKFLOW.md](WORKFLOW.md) - 完整实施工作流
- **Discourse Meta**: [插件讨论区](https://meta.discourse.org/)

---

## 🔗 参考资源 / References

### 官方文档 / Official Documentation

- [钉钉OAuth2.0文档](https://open.dingtalk.com/document/connection/oauth2-0-authentication)
- [Discourse OAuth插件开发指南](https://meta.discourse.org/t/create-a-new-omniauth-provider-for-discourse/153305)
- [OmniAuth OAuth2 Strategy](https://github.com/omniauth/omniauth-oauth2)

### 参考实现 / Reference Implementations

- [discourse-oauth2-basic](https://github.com/discourse/discourse-oauth2-basic)
- [discourse-github](https://github.com/discourse/discourse-github)
- [discourse-google-oauth2](https://github.com/discourse/discourse-google-oauth2)

---

## ⭐ Star History

如果这个插件对您有帮助,请给个Star支持!

---

**Made with ❤️ for the Discourse Community**
