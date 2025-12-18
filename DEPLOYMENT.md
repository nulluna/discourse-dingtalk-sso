# 🚀 Discourse 钉钉 SSO 插件部署检查清单

本文档提供完整的部署验证流程,确保插件正确安装和配置。

---

## 📋 部署前准备

### 环境要求检查

- [ ] Discourse 版本 ≥ 2.7.0
- [ ] 服务器已启用 HTTPS
- [ ] 拥有钉钉企业管理员权限
- [ ] 具备 Discourse 管理员权限

---

## 🔧 阶段一:钉钉开放平台配置

### 1.1 创建企业内部应用

- [ ] 登录 [钉钉开放平台](https://open-dev.dingtalk.com/)
- [ ] 进入"应用开发 > 企业内部开发"
- [ ] 点击"创建应用"
- [ ] 设置应用基本信息:
  - [ ] 应用名称(如: `Discourse 社区登录`)
  - [ ] 应用描述
  - [ ] 应用图标(可选)
- [ ] 记录生成的 **Client ID**
- [ ] 记录生成的 **Client Secret**

### 1.2 配置安全设置

- [ ] 进入 **开发配置 > 安全设置**
- [ ] 在"重定向URL(回调域名)"中添加:
  ```
  https://your-discourse-domain.com/auth/dingtalk/callback
  ```
- [ ] ⚠️ 确认URL格式:
  - [ ] 使用 `https://` 协议
  - [ ] 精确匹配域名(不含端口号)
  - [ ] 路径为 `/auth/dingtalk/callback`
- [ ] 点击"保存"按钮

### 1.3 申请API权限

- [ ] 进入 **开发配置 > 权限管理**
- [ ] 搜索并开通以下权限:
  - [ ] ✅ **个人手机号信息** (`Contact.User.mobile`)
  - [ ] ✅ **通讯录个人信息读权限** (`Contact.User.Read`)
- [ ] 确认权限状态为"已开通"

### 1.4 发布应用

- [ ] 进入 **应用发布 > 版本管理与发布**
- [ ] 填写版本说明
- [ ] 点击"确认发布"
- [ ] 等待审核通过(企业内部应用通常自动通过)
- [ ] 确认应用状态为"已上线"

### ✅ 阶段一验证

- [ ] Client ID 和 Client Secret 已妥善保存
- [ ] 回调URL 已正确配置
- [ ] 必需权限已开通
- [ ] 应用已成功发布

---

## 📦 阶段二:Discourse 插件安装

### 2.1 Docker 标准部署

#### 编辑容器配置

- [ ] SSH 登录到 Discourse 服务器
- [ ] 切换到 Discourse 目录:
  ```bash
  cd /var/discourse
  ```
- [ ] 编辑配置文件:
  ```bash
  nano containers/app.yml
  ```
- [ ] 在 `hooks.after_code` 部分添加:
  ```yaml
  hooks:
    after_code:
      - exec:
          cd: $home/plugins
          cmd:
            - git clone https://github.com/yourusername/discourse-dingtalk-sso.git
  ```
- [ ] 保存并退出 (Ctrl+X, Y, Enter)

#### 重建容器

- [ ] 执行重建命令:
  ```bash
  ./launcher rebuild app
  ```
- [ ] 等待重建完成(约5-10分钟)
- [ ] 确认无错误信息

### 2.2 开发环境部署

- [ ] 进入 Discourse 插件目录:
  ```bash
  cd /path/to/discourse/plugins
  ```
- [ ] 克隆插件仓库:
  ```bash
  git clone https://github.com/yourusername/discourse-dingtalk-sso.git
  ```
- [ ] 安装依赖:
  ```bash
  bundle install
  ```
- [ ] 重启 Rails 服务器

### ✅ 阶段二验证

- [ ] 插件文件已下载到 `plugins/discourse-dingtalk-sso/`
- [ ] 容器/服务器重启成功
- [ ] 无报错或警告信息

---

## ⚙️ 阶段三:Discourse 管理后台配置

### 3.1 启用插件

- [ ] 登录 Discourse 管理员账号
- [ ] 进入 **管理 > 设置 > 登录**
- [ ] 找到"钉钉登录"相关设置

### 3.2 必需配置项

#### 基础配置

- [ ] **dingtalk_enabled**
  - [ ] 勾选启用
  - [ ] 确认状态为"✅"

- [ ] **dingtalk_client_id**
  - [ ] 粘贴钉钉应用的 Client ID
  - [ ] 格式验证: `dingxxxxxxxxx` (字母数字)

- [ ] **dingtalk_client_secret**
  - [ ] 粘贴钉钉应用的 Client Secret
  - [ ] ⚠️ 确保未泄露到日志或版本控制

#### URL配置(使用默认值)

- [ ] **dingtalk_authorize_url**
  - [ ] 确认为: `https://login.dingtalk.com/oauth2/auth`

- [ ] **dingtalk_token_url**
  - [ ] 确认为: `https://api.dingtalk.com/v1.0/oauth2/userAccessToken`

- [ ] **dingtalk_user_info_url**
  - [ ] 确认为: `https://api.dingtalk.com/v1.0/contact/users/me`

#### 可选配置

- [ ] **dingtalk_scope**
  - [ ] 使用默认值: `openid`

- [ ] **dingtalk_button_title**
  - [ ] 中文环境: `使用钉钉登录`
  - [ ] 英文环境: `with DingTalk`

- [ ] **dingtalk_authorize_signup**
  - [ ] 根据策略选择是否允许自动注册
  - [ ] 建议企业内部启用

- [ ] **dingtalk_overrides_email**
  - [ ] 默认关闭(推荐)
  - [ ] 仅在明确需要时启用

### 3.3 保存配置

- [ ] 点击"保存更改"按钮
- [ ] 等待配置生效
- [ ] 刷新页面验证

### ✅ 阶段三验证

- [ ] 所有必需配置项已填写
- [ ] 配置已成功保存
- [ ] 无验证错误提示

---

## 🧪 阶段四:功能测试

### 4.1 登录界面测试

- [ ] 退出当前登录(或使用隐身模式)
- [ ] 访问 Discourse 登录页面
- [ ] 确认显示"使用钉钉登录"按钮
- [ ] 按钮样式正常显示
- [ ] 按钮位置合理

### 4.2 OAuth 授权流程测试

#### 发起登录

- [ ] 点击"使用钉钉登录"按钮
- [ ] 自动跳转到钉钉授权页面
- [ ] URL包含正确的 `client_id`
- [ ] URL包含正确的 `redirect_uri`
- [ ] URL包含正确的 `scope`

#### 授权确认

- [ ] 钉钉授权页面正常显示
- [ ] 显示正确的应用名称和权限列表
- [ ] 点击"同意授权"按钮

#### 回调处理

- [ ] 自动重定向回 Discourse
- [ ] URL包含 `code` 参数
- [ ] 无报错页面

### 4.3 用户创建测试

#### 新用户注册

- [ ] 使用从未登录过的钉钉账号
- [ ] 完成授权后自动创建 Discourse 用户
- [ ] 验证用户信息:
  - [ ] 用户名正确(来自钉钉昵称)
  - [ ] 显示名称正确
  - [ ] 邮箱地址正确
  - [ ] 邮箱状态为"已验证"

#### 老用户登录

- [ ] 使用已关联的钉钉账号登录
- [ ] 直接进入首页(不创建新用户)
- [ ] 用户信息保持一致

### 4.4 账号关联测试

#### 关联流程

- [ ] 使用现有 Discourse 账号登录
- [ ] 进入 **用户设置 > 账户**
- [ ] 找到"关联账户"部分
- [ ] 点击"关联钉钉账号"
- [ ] 完成钉钉授权
- [ ] 确认关联成功

#### 验证关联状态

- [ ] 账户页面显示已关联钉钉
- [ ] 显示钉钉 Union ID
- [ ] "解绑"按钮可用

### 4.5 账号解绑测试

- [ ] 进入用户设置页面
- [ ] 找到已关联的钉钉账号
- [ ] 点击"解绑"按钮
- [ ] 确认解绑提示
- [ ] 验证解绑成功
- [ ] 钉钉登录按钮重新可用

### ✅ 阶段四验证

- [ ] 新用户注册成功
- [ ] 老用户登录成功
- [ ] 用户信息同步正确
- [ ] 账号关联/解绑功能正常

---

## 🔍 阶段五:问题排查

### 5.1 启用调试模式

如遇问题,启用详细日志:

- [ ] 进入 **管理 > 设置 > 登录**
- [ ] 找到 `dingtalk_debug_auth` (隐藏设置)
- [ ] 在浏览器控制台执行:
  ```javascript
  const setting = this.siteSettings.dingtalk_debug_auth;
  ```
- [ ] 或通过 Rails 控制台:
  ```ruby
  SiteSetting.dingtalk_debug_auth = true
  ```

### 5.2 查看日志

- [ ] 查看 Discourse 日志:
  ```bash
  ./launcher logs app
  ```
- [ ] 搜索关键词:
  - `DingTalk auth`
  - `OAuth token error`
  - `dingtalk`

### 5.3 常见问题检查

#### 重定向URL不匹配

- [ ] 确认钉钉后台URL精确匹配
- [ ] 检查协议(http vs https)
- [ ] 验证域名拼写

#### Token获取失败

- [ ] 验证 Client ID 正确
- [ ] 验证 Client Secret 正确
- [ ] 确认应用已发布
- [ ] 检查应用状态为"已上线"

#### 用户信息缺失

- [ ] 确认权限已开通
- [ ] 检查用户钉钉资料完整性
- [ ] 验证企业管理员设置

### ✅ 阶段五验证

- [ ] 所有测试用例通过
- [ ] 问题已排查并解决
- [ ] 日志无异常信息

---

## 🔒 阶段六:安全检查

### 6.1 HTTPS 配置

- [ ] 生产环境强制使用 HTTPS
- [ ] SSL 证书有效
- [ ] 无混合内容警告

### 6.2 密钥安全

- [ ] Client Secret 未提交到版本控制
- [ ] 密钥存储在环境变量或安全配置中
- [ ] 定期轮换密钥(建议6个月)

### 6.3 权限最小化

- [ ] 仅申请必需的API权限
- [ ] 定期审查权限使用情况
- [ ] 移除未使用的权限

### 6.4 回调URL验证

- [ ] 使用精确匹配的URL
- [ ] 避免使用通配符
- [ ] 不允许HTTP协议(生产环境)

### ✅ 阶段六验证

- [ ] HTTPS 已强制启用
- [ ] 密钥安全存储
- [ ] 权限符合最小化原则
- [ ] 回调URL安全配置

---

## 📊 阶段七:性能与监控

### 7.1 性能测试

- [ ] 多用户并发登录测试
- [ ] 响应时间 < 3秒
- [ ] 无超时错误

### 7.2 监控配置

- [ ] 配置错误日志告警
- [ ] 监控 OAuth 失败率
- [ ] 跟踪用户注册数量

### 7.3 备份配置

- [ ] 备份钉钉应用配置截图
- [ ] 记录 Client ID 和 Secret(安全存储)
- [ ] 导出 Discourse 插件配置

### ✅ 阶段七验证

- [ ] 性能测试通过
- [ ] 监控已配置
- [ ] 配置已备份

---

## ✅ 最终验收清单

### 功能完整性

- [ ] ✅ 钉钉登录按钮正常显示
- [ ] ✅ OAuth 授权流程完整
- [ ] ✅ 新用户自动注册
- [ ] ✅ 老用户正常登录
- [ ] ✅ 用户信息正确同步
- [ ] ✅ 账号关联功能正常
- [ ] ✅ 账号解绑功能正常

### 安全性

- [ ] ✅ HTTPS 已启用
- [ ] ✅ Client Secret 安全存储
- [ ] ✅ 回调URL 精确匹配
- [ ] ✅ API 权限最小化

### 稳定性

- [ ] ✅ 错误处理完善
- [ ] ✅ 日志记录清晰
- [ ] ✅ 性能表现良好
- [ ] ✅ 监控已配置

### 文档完整性

- [ ] ✅ README 文档完整
- [ ] ✅ 配置说明清晰
- [ ] ✅ 故障排查指南可用
- [ ] ✅ 用户手册已提供

---

## 📞 上线后支持

### 用户支持

- [ ] 准备用户使用指南
- [ ] 设置支持渠道(邮件/工单)
- [ ] 培训管理员和支持人员

### 持续改进

- [ ] 收集用户反馈
- [ ] 定期检查日志
- [ ] 关注钉钉API更新
- [ ] 跟进 Discourse 版本升级

---

## 🎉 部署完成

恭喜!Discourse 钉钉 SSO 插件已成功部署!

如有问题,请参考:
- [README.md](README.md) - 完整使用文档
- [WORKFLOW.md](WORKFLOW.md) - 技术实施细节
- [GitHub Issues](https://github.com/yourusername/discourse-dingtalk-sso/issues) - 问题反馈

---

**部署日期**: _______________
**部署人员**: _______________
**验收人员**: _______________
**备注**: _______________
