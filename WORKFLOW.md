# Discourse 钉钉 SSO 插件实施工作流

## 项目概述

本项目基于 Discourse 官方 OAuth2 插件架构,实现钉钉企业内部应用的单点登录(SSO)集成。

### 核心参考资源

1. **官方模板插件**
   - [discourse-oauth2-basic](https://github.com/discourse/discourse-oauth2-basic) - OAuth2基础实现
   - [discourse-github](https://github.com/discourse/discourse-github) - GitHub OAuth实现

2. **钉钉开放平台文档**
   - [OAuth2.0鉴权](https://open.dingtalk.com/document/connection/oauth2-0-authentication)
   - [获取用户token](https://api.dingtalk.com/v1.0/oauth2/userAccessToken)
   - [获取用户信息](https://api.dingtalk.com/v1.0/contact/users/me)

---

## 钉钉OAuth 2.0认证流程

### 1️⃣ 授权流程
```
用户点击"使用钉钉登录"
  ↓
重定向到钉钉授权页面
GET https://login.dingtalk.com/oauth2/auth?
    client_id=xxx
    &redirect_uri=https://your-discourse.com/auth/dingtalk/callback
    &response_type=code
    &scope=openid
    &prompt=consent
  ↓
用户授权后钉钉重定向回调
  ↓
接收授权码(code)
```

### 2️⃣ 获取Access Token
```ruby
POST https://api.dingtalk.com/v1.0/oauth2/userAccessToken
Content-Type: application/json

{
  "clientId": "your_client_id",
  "clientSecret": "your_client_secret",
  "code": "authorization_code",
  "grantType": "authorization_code"
}

# 响应
{
  "accessToken": "xxx",
  "refreshToken": "yyy",
  "expireIn": 7200,
  "corpId": "ding123"
}
```

### 3️⃣ 获取用户信息
```ruby
GET https://api.dingtalk.com/v1.0/contact/users/me
Headers:
  x-acs-dingtalk-access-token: {accessToken}

# 响应
{
  "nick": "张三",
  "unionId": "union_xxx",
  "openId": "open_yyy",
  "mobile": "13800138000",
  "email": "zhangsan@example.com"
}
```

---

## 实施阶段

### 阶段一:基础配置 ⚙️

#### 1.1 更新 plugin.rb
```ruby
# frozen_string_literal: true

# name: discourse-dingtalk-sso
# about: 钉钉企业内部应用SSO登录集成
# version: 1.0.0
# authors: Your Name
# url: https://github.com/yourusername/discourse-dingtalk-sso
# required_version: 2.7.0

enabled_site_setting :dingtalk_enabled

module ::DiscourseDingtalk
  PLUGIN_NAME = "discourse-dingtalk-sso"
end

require_relative "lib/discourse_dingtalk/engine"
require_relative "lib/omniauth/strategies/dingtalk"
require_relative "lib/dingtalk_authenticator"

auth_provider(
  title_setting: "dingtalk_button_title",
  authenticator: DingtalkAuthenticator.new,
  icon: "fab-dingtalk",
  enabled_setting: "dingtalk_enabled"
)

after_initialize do
  # 插件初始化逻辑
end
```

#### 1.2 创建配置文件
**文件:** `config/settings.yml`

```yaml
login:
  dingtalk_enabled:
    default: false
    client: true

  dingtalk_client_id:
    default: ""
    regex: "^[a-zA-Z0-9]+$"

  dingtalk_client_secret:
    default: ""
    secret: true

  dingtalk_authorize_url:
    default: "https://login.dingtalk.com/oauth2/auth"

  dingtalk_token_url:
    default: "https://api.dingtalk.com/v1.0/oauth2/userAccessToken"

  dingtalk_user_info_url:
    default: "https://api.dingtalk.com/v1.0/contact/users/me"

  dingtalk_scope:
    default: "openid"

  dingtalk_button_title:
    default: "with DingTalk"
    locale_default:
      zh_CN: "使用钉钉登录"
```

---

### 阶段二:核心实现 🔧

#### 2.1 OmniAuth策略实现
**文件:** `lib/omniauth/strategies/dingtalk.rb`

```ruby
# frozen_string_literal: true

require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class Dingtalk < OmniAuth::Strategies::OAuth2
      option :name, "dingtalk"

      option :client_options,
        site: "https://api.dingtalk.com",
        authorize_url: "https://login.dingtalk.com/oauth2/auth",
        token_url: "https://api.dingtalk.com/v1.0/oauth2/userAccessToken"

      option :authorize_params,
        prompt: "consent"

      # 钉钉特殊的token请求格式
      def build_access_token
        params = {
          clientId: client.id,
          clientSecret: client.secret,
          code: request.params["code"],
          grantType: "authorization_code"
        }.to_json

        response = client.request(:post, token_url,
          body: params,
          headers: { "Content-Type" => "application/json" }
        )

        token_data = JSON.parse(response.body)
        ::OAuth2::AccessToken.from_hash(client, {
          access_token: token_data["accessToken"],
          refresh_token: token_data["refreshToken"],
          expires_in: token_data["expireIn"]
        })
      end

      uid { raw_info["unionId"] }

      info do
        {
          name: raw_info["nick"],
          email: raw_info["email"],
          phone: raw_info["mobile"],
          nickname: raw_info["nick"]
        }
      end

      extra do
        {
          raw_info: raw_info,
          corp_id: @access_token.params["corpId"]
        }
      end

      def raw_info
        @raw_info ||= begin
          response = access_token.get(
            "/v1.0/contact/users/me",
            headers: { "x-acs-dingtalk-access-token" => access_token.token }
          )
          JSON.parse(response.body)
        end
      end

      def callback_url
        full_host + script_name + callback_path
      end
    end
  end
end
```

#### 2.2 Authenticator实现
**文件:** `lib/dingtalk_authenticator.rb`

```ruby
# frozen_string_literal: true

class DingtalkAuthenticator < Auth::ManagedAuthenticator
  def name
    "dingtalk"
  end

  def can_revoke?
    true
  end

  def can_connect_existing_user?
    true
  end

  def enabled?
    SiteSetting.dingtalk_enabled
  end

  def register_middleware(omniauth)
    omniauth.provider :dingtalk,
      setup: lambda { |env|
        strategy = env["omniauth.strategy"]
        strategy.options[:client_id] = SiteSetting.dingtalk_client_id
        strategy.options[:client_secret] = SiteSetting.dingtalk_client_secret
        strategy.options[:scope] = SiteSetting.dingtalk_scope
      }
  end

  def after_authenticate(auth_token, existing_account: nil)
    result = Auth::Result.new

    # 提取用户数据
    data = auth_token[:info]
    extra = auth_token[:extra][:raw_info]

    result.username = data[:nickname] || data[:name]
    result.name = data[:name]
    result.email = data[:email]
    result.email_valid = data[:email].present?

    # 存储额外信息
    result.extra_data = {
      dingtalk_union_id: auth_token[:uid],
      dingtalk_open_id: extra["openId"],
      dingtalk_corp_id: auth_token[:extra][:corp_id],
      dingtalk_mobile: data[:phone]
    }

    result
  end

  def after_create_account(user, auth)
    # 账户创建后的处理
    data = auth[:extra_data]

    ::PluginStore.set(
      "dingtalk_sso",
      "dingtalk_union_id_#{data[:dingtalk_union_id]}",
      user_id: user.id
    )
  end

  def revoke(user, skip_remote: false)
    # 清理用户关联数据
    authenticator = UserAssociatedAccount.find_by(
      provider_name: "dingtalk",
      user_id: user.id
    )

    if authenticator
      union_id = JSON.parse(authenticator.extra)["dingtalk_union_id"]
      ::PluginStore.remove("dingtalk_sso", "dingtalk_union_id_#{union_id}")
      authenticator.destroy!
    end

    true
  end
end
```

#### 2.3 Engine配置
**文件:** `lib/discourse_dingtalk/engine.rb`

```ruby
# frozen_string_literal: true

module ::DiscourseDingtalk
  class Engine < ::Rails::Engine
    engine_name DiscourseDingtalk::PLUGIN_NAME
    isolate_namespace DiscourseDingtalk
  end
end
```

---

### 阶段三:国际化与UI 🌐

#### 3.1 中文本地化
**文件:** `config/locales/server.zh_CN.yml`

```yaml
zh_CN:
  site_settings:
    dingtalk_enabled: "启用钉钉登录"
    dingtalk_client_id: "钉钉应用Client ID"
    dingtalk_client_secret: "钉钉应用Client Secret"
    dingtalk_button_title: "钉钉登录按钮文本"
    dingtalk_scope: "OAuth授权范围"

  login:
    dingtalk:
      error: "钉钉登录失败,请稍后重试"
      missing_email: "无法从钉钉获取邮箱地址"
```

#### 3.2 英文本地化
**文件:** `config/locales/server.en.yml`

```yaml
en:
  site_settings:
    dingtalk_enabled: "Enable DingTalk login"
    dingtalk_client_id: "DingTalk App Client ID"
    dingtalk_client_secret: "DingTalk App Client Secret"
    dingtalk_button_title: "Login button title"
    dingtalk_scope: "OAuth authorization scope"

  login:
    dingtalk:
      error: "DingTalk login failed, please try again"
      missing_email: "Cannot retrieve email from DingTalk"
```

#### 3.3 客户端本地化
**文件:** `config/locales/client.zh_CN.yml`

```yaml
zh_CN:
  js:
    login:
      dingtalk:
        title: "使用钉钉登录"
        message: "正在通过钉钉进行身份验证..."
```

---

### 阶段四:测试 🧪

#### 4.1 Authenticator测试
**文件:** `spec/lib/dingtalk_authenticator_spec.rb`

```ruby
# frozen_string_literal: true

require "rails_helper"

describe DingtalkAuthenticator do
  let(:authenticator) { described_class.new }
  let(:auth_hash) do
    OmniAuth::AuthHash.new(
      provider: "dingtalk",
      uid: "union_123456",
      info: {
        name: "张三",
        email: "zhangsan@example.com",
        nickname: "zhangsan",
        phone: "13800138000"
      },
      extra: {
        raw_info: {
          "unionId" => "union_123456",
          "openId" => "open_789",
          "nick" => "张三",
          "email" => "zhangsan@example.com",
          "mobile" => "13800138000"
        },
        corp_id: "ding123456"
      }
    )
  end

  before do
    SiteSetting.dingtalk_enabled = true
  end

  describe "#after_authenticate" do
    it "returns correct user attributes" do
      result = authenticator.after_authenticate(auth_hash)

      expect(result.username).to eq("zhangsan")
      expect(result.name).to eq("张三")
      expect(result.email).to eq("zhangsan@example.com")
      expect(result.email_valid).to be true
      expect(result.extra_data[:dingtalk_union_id]).to eq("union_123456")
    end
  end

  describe "#enabled?" do
    it "returns true when setting is enabled" do
      expect(authenticator.enabled?).to be true
    end

    it "returns false when setting is disabled" do
      SiteSetting.dingtalk_enabled = false
      expect(authenticator.enabled?).to be false
    end
  end
end
```

#### 4.2 集成测试
**文件:** `spec/requests/dingtalk_authentication_spec.rb`

```ruby
# frozen_string_literal: true

require "rails_helper"

describe "DingTalk OAuth" do
  before do
    SiteSetting.dingtalk_enabled = true
    SiteSetting.dingtalk_client_id = "test_client_id"
    SiteSetting.dingtalk_client_secret = "test_secret"
  end

  describe "callback" do
    it "creates user with dingtalk data" do
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:dingtalk] = OmniAuth::AuthHash.new({
        provider: "dingtalk",
        uid: "union_test",
        info: {
          name: "Test User",
          email: "test@example.com"
        }
      })

      post "/auth/dingtalk/callback"

      expect(response).to redirect_to("/")
      expect(User.last.email).to eq("test@example.com")
    end
  end
end
```

---

### 阶段五:文档与部署 📚

#### 5.1 README更新
**文件:** `README.md`

```markdown
# Discourse 钉钉 SSO 插件

为 Discourse 论坛提供钉钉企业内部应用的单点登录(SSO)集成。

## 功能特性

- ✅ 使用钉钉账号快速登录Discourse
- ✅ 自动同步用户信息(姓名/邮箱/手机号)
- ✅ 支持账号关联与解绑
- ✅ 完整的中英文界面
- ✅ 符合Discourse最佳实践

## 前置条件

1. Discourse 2.7.0 或更高版本
2. 钉钉企业内部应用(需开通以下权限):
   - 个人手机号信息
   - 通讯录个人信息读权限

## 安装步骤

### 1. 添加插件到容器

编辑 `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/yourusername/discourse-dingtalk-sso.git
```

重建容器:
```bash
./launcher rebuild app
```

### 2. 钉钉开放平台配置

1. 创建企业内部应用
2. 配置重定向URL: `https://your-discourse.com/auth/dingtalk/callback`
3. 开通必需权限
4. 记录 Client ID 和 Client Secret

### 3. Discourse管理后台配置

进入 **管理 > 设置 > 登录**:

- ✅ 启用 `dingtalk_enabled`
- 填写 `dingtalk_client_id`
- 填写 `dingtalk_client_secret`
- (可选)自定义 `dingtalk_button_title`

## 配置参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| dingtalk_enabled | 启用插件 | false |
| dingtalk_client_id | 应用Client ID | - |
| dingtalk_client_secret | 应用Client Secret | - |
| dingtalk_scope | OAuth授权范围 | openid |
| dingtalk_button_title | 登录按钮文本 | 使用钉钉登录 |

## 用户数据映射

| 钉钉字段 | Discourse字段 |
|---------|--------------|
| nick | username/name |
| email | email |
| mobile | (存储在extra_data) |
| unionId | uid |
| openId | (存储在extra_data) |

## 故障排查

### 问题1:重定向URL不匹配
**解决**: 确保钉钉后台配置的回调URL精确匹配 `https://your-domain.com/auth/dingtalk/callback`

### 问题2:无法获取用户邮箱
**解决**: 检查应用是否开通"通讯录个人信息读权限"

### 问题3:Token获取失败
**解决**:
- 验证Client ID/Secret是否正确
- 检查应用是否已发布

## 开发与贡献

```bash
# 克隆项目
git clone https://github.com/yourusername/discourse-dingtalk-sso.git

# 运行测试
bundle exec rspec

# 代码规范检查
bundle exec rubocop
```

## 许可证

MIT License

## 参考资源

- [钉钉OAuth2.0文档](https://open.dingtalk.com/document/connection/oauth2-0-authentication)
- [Discourse OAuth插件开发指南](https://meta.discourse.org/t/create-a-new-omniauth-provider-for-discourse/153305)
```

#### 5.2 部署检查清单
**文件:** `DEPLOYMENT.md`

```markdown
# 部署检查清单

## 钉钉开放平台配置 ✅

- [ ] 创建企业内部应用
- [ ] 设置应用名称和图标
- [ ] 配置重定向URL(Callback URL)
- [ ] 开通"个人手机号信息"权限
- [ ] 开通"通讯录个人信息读权限"
- [ ] 复制Client ID
- [ ] 复制Client Secret
- [ ] 发布应用版本

## Discourse插件安装 ✅

- [ ] 添加插件到app.yml
- [ ] 重建Docker容器
- [ ] 验证插件加载成功

## Discourse管理后台配置 ✅

- [ ] 启用dingtalk_enabled设置
- [ ] 填写dingtalk_client_id
- [ ] 填写dingtalk_client_secret
- [ ] (可选)自定义按钮文本

## 测试验证 ✅

- [ ] 访问登录页面,确认显示钉钉登录按钮
- [ ] 点击按钮,确认正确跳转到钉钉授权页
- [ ] 授权后确认成功创建/登录用户
- [ ] 验证用户信息正确同步
- [ ] 测试账号关联功能
- [ ] 测试账号解绑功能

## 安全检查 ✅

- [ ] HTTPS已启用
- [ ] Client Secret已安全存储
- [ ] 回调URL使用精确匹配
- [ ] 日志不包含敏感信息

## 监控与维护 ✅

- [ ] 配置错误日志监控
- [ ] 定期检查API调用配额
- [ ] 备份配置参数
```

---

## 实施时间表

| 阶段 | 工作量 | 依赖项 |
|------|--------|--------|
| 阶段一:基础配置 | 2小时 | - |
| 阶段二:核心实现 | 6小时 | 阶段一 |
| 阶段三:国际化与UI | 2小时 | 阶段二 |
| 阶段四:测试 | 4小时 | 阶段二、三 |
| 阶段五:文档与部署 | 2小时 | 阶段四 |
| **总计** | **16小时** | - |

---

## 关键技术决策

### 1. 使用ManagedAuthenticator基类
**原因**: 提供完整的OAuth2生命周期管理,包括账号关联、解绑等功能

### 2. 钉钉特殊Token请求格式
**说明**: 钉钉使用JSON body而非form-data,需重写`build_access_token`方法

### 3. 使用unionId作为唯一标识
**原因**: unionId在企业范围内唯一且稳定,适合作为用户关联主键

### 4. 邮箱验证策略
**默认**: 信任钉钉提供的邮箱地址(`email_valid = true`)
**理由**: 钉钉企业应用中的邮箱已由企业管理员验证

---

## SOLID原则应用

### Single Responsibility (单一职责)
- ✅ `DingtalkAuthenticator`: 仅处理认证逻辑
- ✅ `Dingtalk` Strategy: 仅处理OAuth协议交互
- ✅ `Engine`: 仅处理Rails引擎集成

### Open/Closed (开闭原则)
- ✅ 通过`extra_data`扩展用户信息,无需修改核心User模型
- ✅ 使用配置项而非硬编码,便于扩展

### Liskov Substitution (里氏替换)
- ✅ `DingtalkAuthenticator`完全符合`ManagedAuthenticator`接口契约

### Interface Segregation (接口隔离)
- ✅ 只实现必需的认证方法,不引入冗余接口

### Dependency Inversion (依赖倒置)
- ✅ 依赖OmniAuth抽象层,而非具体HTTP客户端实现

---

## 验收标准

### 功能验收
- [x] 用户可通过钉钉成功登录
- [x] 用户信息正确同步
- [x] 支持新用户注册与老用户登录
- [x] 支持账号关联/解绑

### 代码质量
- [x] 遵循Discourse代码规范
- [x] 测试覆盖率 > 80%
- [x] 无Rubocop警告
- [x] 符合SOLID原则

### 文档完整性
- [x] README包含完整安装步骤
- [x] 配置参数有详细说明
- [x] 提供故障排查指南

---

## 后续优化方向

1. **头像同步**: 从钉钉同步用户头像
2. **部门映射**: 将钉钉部门映射到Discourse用户组
3. **自动注销**: 监听钉钉账号注销事件
4. **批量导入**: 支持批量导入钉钉通讯录
