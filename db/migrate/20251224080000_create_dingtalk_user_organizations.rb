# frozen_string_literal: true

class CreateDingtalkUserOrganizations < ActiveRecord::Migration[7.0]
  def up
    # 1. 创建企业关联表
    create_table :dingtalk_user_organizations do |t|
      t.integer :user_id, null: false
      t.string :corp_id, null: false, limit: 100
      t.string :union_id, null: false, limit: 100
      t.string :open_id, limit: 100
      t.datetime :first_login_at
      t.datetime :last_login_at
      t.timestamps
    end

    # 2. 添加索引
    add_index :dingtalk_user_organizations, [:user_id, :corp_id], unique: true, name: "idx_dingtalk_user_orgs_user_corp"
    add_index :dingtalk_user_organizations, :union_id, name: "idx_dingtalk_user_orgs_union_id"
    add_index :dingtalk_user_organizations, [:corp_id, :open_id], name: "idx_dingtalk_user_orgs_corp_open"

    # 3. 迁移现有数据
    migrate_existing_data
  end

  def down
    drop_table :dingtalk_user_organizations
  end

  private

  def migrate_existing_data
    # 从 UserAssociatedAccount 迁移历史数据
    puts "开始迁移现有钉钉用户的企业关联数据..."

    migrated_count = 0
    skipped_count = 0
    error_count = 0

    DB.query(<<~SQL).each do |row|
      SELECT
        id,
        user_id,
        provider_uid,
        extra,
        created_at,
        last_used
      FROM user_associated_accounts
      WHERE provider_name = 'dingtalk'
    SQL

      begin
        # 解析 extra 字段 (JSON 格式)
        extra_data = JSON.parse(row.extra) rescue {}

        # 尝试多个路径获取 corp_id
        corp_id = extra_data["corp_id"] ||
                  extra_data.dig("raw_info", "corpId") ||
                  extra_data["corpId"]

        # 如果没有 corp_id，跳过（可能是旧数据）
        unless corp_id.present?
          skipped_count += 1
          next
        end

        # 尝试获取 open_id
        open_id = extra_data.dig("raw_info", "openId") ||
                  extra_data["openId"]

        # 插入企业关联记录
        DB.exec(
          <<~SQL,
            INSERT INTO dingtalk_user_organizations
            (user_id, corp_id, union_id, open_id, first_login_at, last_login_at, created_at, updated_at)
            VALUES (:user_id, :corp_id, :union_id, :open_id, :first_login_at, :last_login_at, :created_at, :updated_at)
            ON CONFLICT (user_id, corp_id) DO NOTHING
          SQL
          user_id: row.user_id,
          corp_id: corp_id,
          union_id: row.provider_uid,
          open_id: open_id,
          first_login_at: row.created_at,
          last_login_at: row.last_used || row.created_at,
          created_at: row.created_at,
          updated_at: Time.zone.now
        )

        migrated_count += 1

      rescue => e
        puts "  ⚠️  迁移记录 ID=#{row.id} 失败: #{e.message}"
        error_count += 1
      end
    end

    puts "✅ 迁移完成: 成功 #{migrated_count} 条, 跳过 #{skipped_count} 条 (无corp_id), 错误 #{error_count} 条"
  rescue => e
    puts "⚠️  数据迁移过程中发生错误: #{e.message}"
    puts "   这不会影响新功能的使用，现有用户下次登录时会自动创建关联记录"
  end
end
