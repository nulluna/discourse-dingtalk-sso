# frozen_string_literal: true

# 钉钉用户-企业关联模型
# 用于记录同一用户在多个钉钉企业中的关联关系
class DingtalkUserOrganization < ActiveRecord::Base
  belongs_to :user

  validates :user_id, presence: true
  validates :corp_id, presence: true, length: { maximum: 100 }
  validates :union_id, presence: true, length: { maximum: 100 }
  validates :corp_id, uniqueness: { scope: :user_id }

  # 获取用户关联的所有企业
  # @param user_id [Integer] Discourse 用户ID
  # @return [ActiveRecord::Relation<DingtalkUserOrganization>]
  def self.organizations_for_user(user_id)
    where(user_id: user_id)
      .order(last_login_at: :desc)
  end

  # 获取企业下的所有用户
  # @param corp_id [String] 钉钉企业ID
  # @return [ActiveRecord::Relation<DingtalkUserOrganization>]
  def self.users_for_organization(corp_id)
    where(corp_id: corp_id)
      .includes(:user)
      .order(last_login_at: :desc)
  end

  # 查找用户在指定企业的关联记录
  # @param user_id [Integer] Discourse 用户ID
  # @param corp_id [String] 钉钉企业ID
  # @return [DingtalkUserOrganization, nil]
  def self.find_by_user_and_corp(user_id, corp_id)
    find_by(user_id: user_id, corp_id: corp_id)
  end

  # 更新最后登录时间
  # @return [Boolean]
  def touch_last_login!
    update(last_login_at: Time.zone.now)
  end

  # 获取所有企业ID列表（用于统计）
  # @return [Array<String>]
  def self.all_corp_ids
    distinct.pluck(:corp_id)
  end

  # 获取企业的用户数统计
  # @return [Hash] { corp_id => user_count }
  def self.organization_user_counts
    group(:corp_id).count
  end
end
