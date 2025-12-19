# frozen_string_literal: true

require "digest/md5"

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

  # 覆盖全局注册设置,允许钉钉用户独立注册
  # Override global registration setting to allow DingTalk users to register independently
  def authorize_new_users?
    SiteSetting.dingtalk_authorize_signup
  end

  # 总是更新用户邮箱(当钉钉邮箱变更时)
  def always_update_user_email?
    SiteSetting.dingtalk_overrides_email
  end

  def primary_email_verified?(auth_token)
    # Only real DingTalk emails (not virtual ones) are considered verified
    email = auth_token.dig(:info, :email)
    return false if email.blank?

    # Check if it's not a virtual email domain
    !email.end_with?("@#{SiteSetting.dingtalk_mobile_email_domain}") &&
    !email.end_with?("@#{SiteSetting.dingtalk_virtual_email_domain}")
  end

  def register_middleware(omniauth)
    omniauth.provider :dingtalk,
      setup: lambda { |env|
        strategy = env["omniauth.strategy"]

        # Configure OAuth client credentials
        strategy.options[:client_id] = SiteSetting.dingtalk_client_id
        strategy.options[:client_secret] = SiteSetting.dingtalk_client_secret

        # Configure OAuth URLs
        strategy.options[:client_options][:authorize_url] =
          SiteSetting.dingtalk_authorize_url
        strategy.options[:client_options][:token_url] =
          SiteSetting.dingtalk_token_url

        # Configure scope
        strategy.options[:scope] = SiteSetting.dingtalk_scope

        # Debug mode
        if SiteSetting.dingtalk_debug_auth
          strategy.options[:logger] = Rails.logger
        end
      }
  end

  def after_authenticate(auth_token, existing_account: nil)
    result = Auth::Result.new

    # Validate auth_token structure
    unless auth_token.is_a?(Hash) && auth_token[:uid].present?
      Rails.logger.error "DingTalk: Invalid auth_token structure"
      result.failed = true
      result.failed_reason = I18n.t("login.dingtalk.error")
      return result
    end

    # Extract user data from OAuth response
    data = auth_token[:info] || {}
    extra = auth_token.dig(:extra, :raw_info) || {}
    uid = auth_token[:uid]

    # === 用户名生成逻辑 ===
    # 优先使用明确的nickname字段（如果存在）
    # 如果nickname不存在，使用模板生成（模板中可使用name等变量）
    nickname = extract_dingtalk_nickname(data, extra)
    nickname_field = data[:nickname] # 明确的nickname字段

    if nickname_field.present?
      # 如果有明确的nickname字段，优先使用
      result.username = sanitize_username(nickname_field)
    end

    if result.username.blank?
      # nickname不存在或无效，使用模板生成
      result.username = generate_username_from_template(uid, data)
      Rails.logger.warn "DingTalk: Generated username from template: #{result.username}"
    end

    # === 姓名直接使用钉钉数据 ===
    # 优先使用 name 字段（通常是中文显示名），fallback 到 nickname 或 username
    result.name = data[:name].presence || extra["nick"].presence || nickname.presence || result.username

    # === 邮箱生成逻辑（渐进式降级） ===
    email_info = generate_email_with_fallback(data, extra, uid)
    result.email = email_info[:email]
    result.email_valid = email_info[:valid]

    # 不再强制要求邮箱，允许虚拟邮箱
    if result.email.blank?
      Rails.logger.error "DingTalk: Failed to generate email for user #{result.username}"
      result.failed = true
      result.failed_reason = I18n.t("login.dingtalk.error")
      return result
    end

    # 记录虚拟邮箱使用情况
    unless email_info[:valid]
      Rails.logger.info "DingTalk: Virtual email assigned for #{result.username}: #{result.email}"
    end

    # Store DingTalk-specific data
    result.extra_data = {
      dingtalk_union_id: auth_token[:uid],
      dingtalk_open_id: extra["openId"],
      dingtalk_corp_id: auth_token.dig(:extra, :corp_id),
      dingtalk_mobile: data[:phone]
    }

    # Handle email conflicts
    if SiteSetting.dingtalk_overrides_email && result.email.present?
      result.skip_email_validation = true
    end

    # Log authentication for debugging
    if SiteSetting.dingtalk_debug_auth
      Rails.logger.info "DingTalk auth result: username=#{result.username}, email=#{result.email}, email_valid=#{result.email_valid}, uid=#{auth_token[:uid]}"
      Rails.logger.info "DingTalk auth: will use email matching for existing users" if result.email_valid
    end

    result
  rescue StandardError => e
    Rails.logger.error "DingTalk authentication error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
    result.failed = true
    result.failed_reason = I18n.t("login.dingtalk.error")
    result
  end

  def after_create_account(user, auth)
    data = auth[:extra_data]

    # Set user custom fields if needed
    if data[:dingtalk_mobile].present?
      user.custom_fields["dingtalk_mobile"] = data[:dingtalk_mobile]
      user.save_custom_fields
    end

    Rails.logger.info "DingTalk user created: #{user.username} (Union ID: #{data[:dingtalk_union_id]})"
  end

  def revoke(user, skip_remote: false)
    # Clean up user association data
    authenticator = UserAssociatedAccount.find_by(
      provider_name: "dingtalk",
      user_id: user.id
    )

    if authenticator
      # Remove custom fields
      user.custom_fields.delete("dingtalk_mobile")
      user.save_custom_fields

      authenticator.destroy!

      Rails.logger.info "DingTalk auth revoked for user: #{user.username}"
    end

    true
  end

  def description_for_user(user)
    info = UserAssociatedAccount.find_by(
      provider_name: "dingtalk",
      user_id: user.id
    )

    return "" unless info

    begin
      extra_data = JSON.parse(info.extra)
      union_id = extra_data["dingtalk_union_id"]
      I18n.t("login.dingtalk.description", union_id: union_id)
    rescue JSON::ParserError => e
      Rails.logger.warn "DingTalk: Failed to parse extra data for user #{user.id}: #{e.message}"
      ""
    end
  end

  private

  # 从钉钉数据中提取昵称/姓名
  def extract_dingtalk_nickname(data, extra)
    data[:nickname] || data[:name] || extra["nick"] || ""
  end

  # 安全截断 uid（确保不会因长度不足而出错）
  def safe_truncate_uid(uid, length = 16)
    return uid if uid.length <= length
    uid[0...length]
  end

  # 生成邮箱（渐进式降级：真实邮箱 → 手机虚拟邮箱 → UnionId虚拟邮箱）
  def generate_email_with_fallback(data, extra, uid)
    # 1. 优先真实邮箱
    return { email: data[:email], valid: true } if data[:email].present?

    # 检查是否允许虚拟邮箱
    unless SiteSetting.dingtalk_allow_virtual_email
      return { email: nil, valid: false }
    end

    # 2. 手机号虚拟邮箱
    mobile = data[:phone] || extra["mobile"]
    if mobile.present?
      mobile_domain = SiteSetting.dingtalk_mobile_email_domain
      return {
        email: "#{mobile}@#{mobile_domain}",
        valid: false
      }
    end

    # 3. UnionId 虚拟邮箱（最终降级）
    domain = SiteSetting.dingtalk_virtual_email_domain
    uid_truncated = safe_truncate_uid(uid, 16)
    {
      email: "dingtalk_#{uid_truncated}@#{domain}",
      valid: false
    }
  end

  # 根据模板生成用户名
  def generate_username_from_template(uid, data = {})
    template = SiteSetting.dingtalk_username_template

    # 计算 UnionID 的 MD5 hash
    hash_full = Digest::MD5.hexdigest(uid)

    # 获取并清洗姓名
    name = data[:name] || data[:nickname] || ""
    sanitized_name = sanitize_username(name)

    # 替换模板变量
    uid_truncated = safe_truncate_uid(uid, 16)
    username = template
      .gsub("{hash6}", hash_full[0..5])
      .gsub("{hash8}", hash_full[0..7])
      .gsub("{unionid}", uid_truncated)
      .gsub("{name}", sanitized_name.presence || "user")

    username = username.downcase

    # 验证生成的用户名，如果无效则使用后备方案
    sanitized_result = sanitize_username(username)
    if sanitized_result.blank?
      # 后备方案：使用 dingtalk_ + hash6
      username = "dingtalk_#{hash_full[0..5]}"
      Rails.logger.warn "DingTalk: Template generated invalid username, using fallback: #{username}"
    else
      username = sanitized_result
    end

    username
  end

  def sanitize_username(username)
    return "" if username.blank?

    # Convert to string and normalize
    username = username.to_s.strip

    # For Chinese or special characters, try to transliterate
    # Remove special characters, keep alphanumeric, underscore, hyphen
    sanitized = username
      .unicode_normalize(:nfkd)
      .gsub(/[^\w\-]/, "_")
      .gsub(/_{2,}/, "_")
      .downcase

    # Ensure username meets Discourse requirements
    # - Length between 3-20 characters
    # - Starts with alphanumeric
    # - Only contains alphanumeric, underscore, hyphen

    # Remove leading/trailing underscores/hyphens
    sanitized = sanitized.gsub(/^[\-_]+|[\-_]+$/, "")

    # Ensure it starts with alphanumeric
    unless sanitized =~ /^[a-z0-9]/
      sanitized = "u_#{sanitized}"
    end

    # Truncate if too long (max 20 chars for Discourse)
    sanitized = sanitized[0..19] if sanitized.length > 20

    # Ensure minimum length (min 3 chars) using ljust
    sanitized = sanitized.ljust(3, "_") if sanitized.length < 3

    # Return empty if still invalid after all processing
    sanitized =~ /^[a-z0-9][a-z0-9_\-]{1,18}[a-z0-9]$/i ? sanitized : ""
  end
end
