# 钉钉SSO多组织支持升级方案

## 一、现状分析

### 1.1 当前架构

当前插件采用**单组织模式**:
- 配置单一的 `client_id` 和 `client_secret`
- 使用 `unionId` 作为用户唯一标识 (`provider_uid`)
- 存储 `corpId` 在 `extra_data` 中但未用于用户识别
- 认证流程: OAuth2.0 → 获取 unionId → 匹配/创建用户

### 1.2 数据库结构

**UserAssociatedAccount 表字段**:
```ruby
["id", "provider_name", "provider_uid", "user_id", "last_used",
 "info", "credentials", "extra", "created_at", "updated_at"]
```

**当前存储方式**:
- `provider_name`: "dingtalk"
- `provider_uid`: unionId (来自钉钉API)
- `extra`: 包含 `{ corp_id: "xxx", raw_info: {...} }`

### 1.3 关键代码位置

| 文件 | 职责 |
|------|------|
| `lib/omniauth/strategies/dingtalk.rb:99` | 设置 `uid { raw_info["unionId"] }` |
| `lib/omniauth/strategies/dingtalk.rb:113` | 提取 `corp_id` 存入 extra |
| `lib/dingtalk_authenticator.rb:143-147` | 保存 extra_data (含 corp_id) |
| `lib/dingtalk_authenticator.rb:188-206` | 创建 UserAssociatedAccount |

---

## 二、关键问题解答

### 2.1 UnionID 会不会重复?

**✅ 不会重复 - 但有重要前提**

根据钉钉官方文档和实践:

1. **全局唯一性**
   - UnionID 在**同一个开发者账号/应用**范围内对用户全局唯一
   - 用户加入多个企业(corpId不同)时,通过**同一个应用**获取的 unionId 保持一致

2. **多组织场景示例**
   ```
   用户"张三"的钉钉账号:
   - 在企业A (corpId=A123) 登录你的应用 → unionId=U789
   - 在企业B (corpId=B456) 登录你的应用 → unionId=U789 (相同!)

   结论: 同一个人在多个企业都会映射到 Discourse 的同一个用户账号
   ```

3. **⚠️ 注意事项**
   - 前提: 使用**同一个** client_id/client_secret (同一个钉钉应用)
   - 如果使用不同的钉钉应用, unionId 会不同
   - 当前架构已经满足这一前提

**结论**: 当前使用 unionId 作为 provider_uid 的方案在多组织场景下是安全的,不会产生重复。

### 2.2 为什么需要升级支持多组织?

虽然 unionId 不会重复,但多组织支持仍然有价值:

1. **业务需求**
   - 区分用户来自哪个企业 (审计/统计)
   - 按企业实施不同的权限策略
   - 支持同一用户在不同企业的不同身份

2. **数据完整性**
   - 记录用户的所有企业关联关系
   - 追踪用户的登录来源企业

3. **灵活性**
   - 未来可能需要限制特定企业的访问
   - 支持企业级的批量管理

---

## 三、升级方案设计

### 3.1 方案对比

#### 方案A: 保持现有 unionId 唯一标识,额外记录企业关系 (推荐)

**设计思路**:
- ✅ 保持 `provider_uid = unionId` (向后兼容)
- ✅ 新增数据库表记录用户的多企业关联
- ✅ 用户跨企业登录时自动合并到同一账号

**优点**:
- 完全向后兼容,无需迁移数据
- 符合钉钉 unionId 的设计初衷
- 实现简单,风险低

**缺点**:
- 无法为同一用户在不同企业创建独立账号

#### 方案B: 改用 `unionId + corpId` 组合键

**设计思路**:
- ❌ 修改 `provider_uid = "#{unionId}@#{corpId}"`
- ❌ 同一用户在不同企业创建不同账号

**优点**:
- 可以为同一人在不同企业创建独立身份

**缺点**:
- ❌ 需要数据迁移,破坏现有关联
- ❌ 违背钉钉 unionId 的统一身份设计
- ❌ 用户体验差(同一人多个账号)

---

### 3.2 推荐方案详细设计 (方案A)

#### 3.2.1 数据库设计

**新增表**: `dingtalk_user_organizations`

```ruby
class CreateDingtalkUserOrganizations < ActiveRecord::Migration[7.0]
  def change
    create_table :dingtalk_user_organizations do |t|
      t.integer :user_id, null: false
      t.string :corp_id, null: false, limit: 100
      t.string :union_id, null: false, limit: 100
      t.string :open_id, limit: 100
      t.datetime :first_login_at
      t.datetime :last_login_at
      t.timestamps
    end

    add_index :dingtalk_user_organizations, [:user_id, :corp_id], unique: true
    add_index :dingtalk_user_organizations, :union_id
    add_index :dingtalk_user_organizations, [:corp_id, :open_id]
  end
end
```

**字段说明**:
- `user_id`: Discourse 用户ID
- `corp_id`: 钉钉企业ID
- `union_id`: 钉钉 UnionID (冗余存储,便于查询)
- `open_id`: 钉钉 OpenID (企业内唯一标识)
- `first_login_at`: 首次从该企业登录时间
- `last_login_at`: 最后一次从该企业登录时间

#### 3.2.2 核心逻辑修改

**lib/dingtalk_authenticator.rb**

```ruby
def after_authenticate(auth_token, existing_account: nil)
  # ... 现有代码 ...

  # 调用父类方法创建/匹配用户
  result = super(auth_token, existing_account: existing_account)

  # 🆕 新增: 记录企业关联关系
  if result.user
    track_organization_association(
      user: result.user,
      union_id: uid,
      corp_id: auth_token.dig(:extra, :corp_id),
      open_id: extra["openId"]
    )
  end

  # ... 现有代码 ...
end

private

def track_organization_association(user:, union_id:, corp_id:, open_id:)
  return unless corp_id.present? && union_id.present?

  association = DingtalkUserOrganization.find_or_initialize_by(
    user_id: user.id,
    corp_id: corp_id
  )

  # 首次登录记录时间
  association.first_login_at ||= Time.zone.now

  # 更新最后登录时间和ID
  association.last_login_at = Time.zone.now
  association.union_id = union_id
  association.open_id = open_id if open_id.present?

  association.save!

  Rails.logger.info "DingTalk: Tracked org association - user_id=#{user.id}, corp_id=#{corp_id}, union_id=#{union_id}"
rescue StandardError => e
  Rails.logger.error "DingTalk: Failed to track org association - #{e.message}"
  # 不阻断登录流程
end
```

#### 3.2.3 Model 定义

**models/dingtalk_user_organization.rb** (新增)

```ruby
# frozen_string_literal: true

class DingtalkUserOrganization < ActiveRecord::Base
  belongs_to :user

  validates :user_id, presence: true
  validates :corp_id, presence: true, length: { maximum: 100 }
  validates :union_id, presence: true, length: { maximum: 100 }
  validates :corp_id, uniqueness: { scope: :user_id }

  # 获取用户关联的所有企业
  def self.organizations_for_user(user_id)
    where(user_id: user_id)
      .order(last_login_at: :desc)
  end

  # 获取企业下的所有用户
  def self.users_for_organization(corp_id)
    where(corp_id: corp_id)
      .includes(:user)
      .order(last_login_at: :desc)
  end

  # 查找用户在指定企业的关联记录
  def self.find_by_user_and_corp(user_id, corp_id)
    find_by(user_id: user_id, corp_id: corp_id)
  end
end
```

#### 3.2.4 配置增强 (可选)

**config/settings.yml** (新增配置)

```yaml
dingtalk_track_organizations:
  default: true
  client: true
  description: "记录用户的企业关联关系 / Track user-organization associations"

dingtalk_allowed_corp_ids:
  default: ""
  type: list
  list_type: compact
  description: "允许登录的企业ID白名单(留空=全部允许) / Allowed corp IDs whitelist (empty = allow all)"

dingtalk_blocked_corp_ids:
  default: ""
  type: list
  list_type: compact
  description: "禁止登录的企业ID黑名单 / Blocked corp IDs blacklist"
```

**认证逻辑增强** (可选的企业访问控制):

```ruby
def after_authenticate(auth_token, existing_account: nil)
  # ... 现有代码 ...

  corp_id = auth_token.dig(:extra, :corp_id)

  # 🆕 企业访问控制 (可选)
  if SiteSetting.dingtalk_track_organizations && corp_id.present?
    if !is_organization_allowed?(corp_id)
      result = Auth::Result.new
      result.failed = true
      result.failed_reason = I18n.t("login.dingtalk.organization_not_allowed")
      Rails.logger.warn "DingTalk: Login rejected for corp_id=#{corp_id}"
      return result
    end
  end

  # ... 现有代码 ...
end

private

def is_organization_allowed?(corp_id)
  # 检查黑名单
  blocked = SiteSetting.dingtalk_blocked_corp_ids.split("|").map(&:strip)
  return false if blocked.include?(corp_id)

  # 检查白名单 (如果配置了)
  allowed = SiteSetting.dingtalk_allowed_corp_ids.split("|").map(&:strip)
  return true if allowed.empty? # 未配置白名单=允许所有

  allowed.include?(corp_id)
end
```

---

## 四、升级步骤

### 4.1 数据迁移

```ruby
# db/migrate/20250124_create_dingtalk_user_organizations.rb
class CreateDingtalkUserOrganizations < ActiveRecord::Migration[7.0]
  def up
    # 1. 创建表
    create_table :dingtalk_user_organizations do |t|
      t.integer :user_id, null: false
      t.string :corp_id, null: false, limit: 100
      t.string :union_id, null: false, limit: 100
      t.string :open_id, limit: 100
      t.datetime :first_login_at
      t.datetime :last_login_at
      t.timestamps
    end

    add_index :dingtalk_user_organizations, [:user_id, :corp_id], unique: true
    add_index :dingtalk_user_organizations, :union_id
    add_index :dingtalk_user_organizations, [:corp_id, :open_id]

    # 2. 迁移现有数据
    migrate_existing_data
  end

  def down
    drop_table :dingtalk_user_organizations
  end

  private

  def migrate_existing_data
    # 从 UserAssociatedAccount 迁移历史数据
    UserAssociatedAccount.where(provider_name: "dingtalk").find_each do |assoc|
      begin
        extra_data = assoc.extra.is_a?(Hash) ? assoc.extra : JSON.parse(assoc.extra)
        corp_id = extra_data["corp_id"] || extra_data.dig("raw_info", "corpId")

        next unless corp_id.present?

        DingtalkUserOrganization.create!(
          user_id: assoc.user_id,
          corp_id: corp_id,
          union_id: assoc.provider_uid,
          open_id: extra_data.dig("raw_info", "openId"),
          first_login_at: assoc.created_at,
          last_login_at: assoc.last_used,
          created_at: assoc.created_at,
          updated_at: assoc.updated_at
        )

        Rails.logger.info "Migrated DingTalk org association: user_id=#{assoc.user_id}, corp_id=#{corp_id}"
      rescue => e
        Rails.logger.error "Failed to migrate DingTalk association #{assoc.id}: #{e.message}"
      end
    end
  end
end
```

### 4.2 代码变更清单

| 文件 | 变更类型 | 说明 |
|------|---------|------|
| `db/migrate/xxx_create_dingtalk_user_organizations.rb` | 新增 | 数据库迁移 |
| `models/dingtalk_user_organization.rb` | 新增 | Model 定义 |
| `lib/dingtalk_authenticator.rb` | 修改 | 添加 `track_organization_association` 方法 |
| `config/settings.yml` | 修改 | 新增配置项 (可选) |
| `config/locales/server.zh_CN.yml` | 修改 | 新增多语言文本 |

### 4.3 测试策略

**单元测试**:
```ruby
# spec/models/dingtalk_user_organization_spec.rb
RSpec.describe DingtalkUserOrganization do
  it "allows same user to associate with multiple organizations" do
    user = Fabricate(:user)

    org1 = DingtalkUserOrganization.create!(
      user: user,
      corp_id: "corp_A",
      union_id: "union123"
    )

    org2 = DingtalkUserOrganization.create!(
      user: user,
      corp_id: "corp_B",
      union_id: "union123"
    )

    expect(DingtalkUserOrganization.organizations_for_user(user.id).count).to eq(2)
  end

  it "prevents duplicate corp_id for same user" do
    user = Fabricate(:user)

    DingtalkUserOrganization.create!(
      user: user,
      corp_id: "corp_A",
      union_id: "union123"
    )

    expect {
      DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )
    }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
```

**集成测试**:
```ruby
# spec/lib/dingtalk_authenticator_spec.rb (新增场景)
describe "multi-organization support" do
  it "tracks organization association on login" do
    # 模拟用户从企业A登录
    auth_token = {
      uid: "union123",
      info: { name: "张三", email: "test@example.com" },
      extra: {
        corp_id: "corp_A",
        raw_info: { "openId" => "open_A" }
      }
    }

    result = authenticator.after_authenticate(auth_token)

    expect(result.user).to be_present
    org = DingtalkUserOrganization.find_by(
      user_id: result.user.id,
      corp_id: "corp_A"
    )
    expect(org).to be_present
    expect(org.union_id).to eq("union123")
  end

  it "merges same user from different organizations" do
    # 用户从企业A登录
    auth1 = {
      uid: "union123",
      info: { name: "张三", email: "test@example.com" },
      extra: { corp_id: "corp_A" }
    }
    result1 = authenticator.after_authenticate(auth1)
    user_id_1 = result1.user.id

    # 同一用户从企业B登录
    auth2 = {
      uid: "union123", # 相同的 unionId
      info: { name: "张三", email: "test@example.com" },
      extra: { corp_id: "corp_B" }
    }
    result2 = authenticator.after_authenticate(auth2)
    user_id_2 = result2.user.id

    # 应该映射到同一个用户
    expect(user_id_1).to eq(user_id_2)

    # 应该有两条企业关联记录
    orgs = DingtalkUserOrganization.organizations_for_user(user_id_1)
    expect(orgs.count).to eq(2)
    expect(orgs.map(&:corp_id)).to contain_exactly("corp_A", "corp_B")
  end
end
```

---

## 五、风险评估与缓解

### 5.1 风险分析

| 风险 | 等级 | 缓解措施 |
|------|------|---------|
| 数据迁移失败 | 中 | 迁移代码包含异常处理,不阻断业务 |
| 性能影响 | 低 | 新增轻量级表,查询有索引 |
| 向后兼容性 | 低 | 不修改核心认证逻辑,仅新增功能 |
| corp_id 缺失 | 低 | 代码中检查 `corp_id.present?`,优雅降级 |

### 5.2 回滚方案

如果升级后出现问题:

1. **数据库回滚**
   ```bash
   bundle exec rails db:rollback
   ```

2. **代码回滚**
   - 移除 `track_organization_association` 调用
   - 删除 Model 文件

3. **配置回滚**
   - 删除新增的配置项

---

## 六、未来扩展

### 6.1 管理界面 (可选)

在 Admin 面板添加:
- 查看用户的企业关联列表
- 企业白名单/黑名单管理
- 统计各企业的用户数量

### 6.2 API 支持 (可选)

暴露 API 查询:
- `GET /admin/plugins/dingtalk/organizations` - 企业列表
- `GET /admin/plugins/dingtalk/users/:id/organizations` - 用户的企业

---

## 七、总结

### 7.1 关键结论

1. **UnionID 不会重复**: 在同一应用内,用户跨企业的 unionId 保持一致
2. **推荐方案**: 保持现有 unionId 唯一标识,新增表记录企业关系
3. **向后兼容**: 无需修改核心认证逻辑,仅添加增强功能
4. **风险可控**: 迁移逻辑简单,失败不影响现有用户

### 7.2 实施建议

**最小可行方案** (MVP):
- 仅实施 3.2.1 (数据库) 和 3.2.2 (核心逻辑)
- 跳过企业访问控制

**完整方案**:
- 实施所有功能包括访问控制
- 添加管理界面和统计功能

### 7.3 优先级

1. **高优先级**: 数据库表 + 关联记录逻辑
2. **中优先级**: 企业访问控制配置
3. **低优先级**: 管理界面和 API

---

## 八、参考资料

### 8.1 钉钉官方文档

- [根据unionid获取用户userid](https://open.dingtalk.com/document/isvapp/query-a-user-by-the-union-id)
- [钉钉 userid、unionid、staffId 说明](https://developer.aliyun.com/article/1289970)
- [OAuth 2.0 认证协议](https://apifox.com/apiskills/how-to-use-dingding-oauth2/)

### 8.2 技术要点

- UnionID 在同一应用内跨企业唯一
- OAuth 回调中通过 scope 参数可获取 corpId
- corpId 标识用户选择的企业组织

---

**文档版本**: v1.0
**创建时间**: 2025-01-24
**最后更新**: 2025-01-24
