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
    # All DingTalk SSO emails are considered verified (including virtual emails)
    # DingTalk SSO has already authenticated the user's identity, so we trust the email
    # This allows users to login directly without email verification
    email = auth_token.dig(:info, :email)
    email.present?
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
    start_time = Time.current  # Track authentication duration for debugging

    # Validate auth_token structure
    unless auth_token.is_a?(Hash) && auth_token[:uid].present?
      result = Auth::Result.new
      Rails.logger.error "DingTalk: Invalid auth_token structure - #{auth_token.inspect}"
      result.failed = true
      result.failed_reason = I18n.t("login.dingtalk.error")
      return result
    end

    # Extract user data from OAuth response
    data = auth_token[:info] || {}
    extra = auth_token.dig(:extra, :raw_info) || {}
    uid = auth_token[:uid]

    # === 准备用户信息 ===
    nickname = extract_dingtalk_nickname(data, extra)
    nickname_field = data[:nickname]

    username = nil
    if nickname_field.present?
      username = UserNameSuggester.fix_username(nickname_field)
    end

    if username.blank?
      username = generate_username_from_template(uid, data, extra)
      Rails.logger.warn "DingTalk: Generated username from template: #{username}"
    end

    # 姓名（用于显示）
    name = data[:name].presence || extra["nick"].presence || nickname.presence || username

    # 邮箱生成（渐进式降级）
    email_info = generate_email_with_fallback(data, extra, uid)
    email = email_info[:email]
    email_valid = email_info[:valid]

    if email.blank?
      result = Auth::Result.new
      Rails.logger.error "DingTalk: Failed to generate email for user #{username}"
      result.failed = true
      result.failed_reason = I18n.t("login.dingtalk.error")
      return result
    end

    # 🆕 企业访问控制检查（可选功能）
    corp_id = auth_token.dig(:extra, :corp_id)
    if SiteSetting.dingtalk_track_organizations && corp_id.present?
      unless is_organization_allowed?(corp_id)
        result = Auth::Result.new
        result.failed = true
        result.failed_reason = I18n.t("login.dingtalk.organization_not_allowed")
        Rails.logger.warn "DingTalk: Login rejected for corp_id=#{corp_id}"
        return result
      end
    end

    # 记录虚拟邮箱使用情况
    unless email_valid
      Rails.logger.info "DingTalk: Virtual email assigned for #{username}: #{email}"
    end

    # 覆盖 auth_token 中的 info，确保父类 ManagedAuthenticator 使用正确的数据
    auth_token[:info] = {
      nickname: username,
      name: name,
      email: email,
      phone: data[:phone]
    }

    # 调用父类方法，利用 ManagedAuthenticator 的用户匹配逻辑
    result = super(auth_token, existing_account: existing_account)

    # 🔥 需求1：绑定时自动填充用户全名
    if existing_account && SiteSetting.dingtalk_auto_fill_user_name
      if existing_account.name.blank? && name.present?
        existing_account.name = name
        existing_account.save!
        Rails.logger.info "DingTalk: Auto-filled user name for #{existing_account.username}: #{name}"
      end
    end

    # 强制设置 email_valid（SSO 已验证身份，信任所有邮箱）
    result.email_valid = true if result.email.present?

    # Store DingTalk-specific data
    result.extra_data = {
      dingtalk_union_id: uid,
      dingtalk_open_id: extra["openId"],
      dingtalk_corp_id: auth_token.dig(:extra, :corp_id),
      dingtalk_mobile: data[:phone]
    }

    # 🔥 关键修复：如果启用自动注册且用户不存在，立即创建用户
    if result.user.nil? && SiteSetting.dingtalk_authorize_signup
      Rails.logger.info "DingTalk: Creating new user automatically - #{username}"

      # 创建新用户（使用事务确保原子性）
      begin
        User.transaction do
          user = User.new(
            email: result.email,
            username: UserNameSuggester.suggest(username),
            name: name,
            active: true, # 直接激活
            approved: !SiteSetting.must_approve_users?, # 根据站点设置决定是否需要审批
            approved_at: SiteSetting.must_approve_users? ? nil : Time.zone.now,
            approved_by_id: SiteSetting.must_approve_users? ? nil : Discourse.system_user.id
          )

          # 生成随机密码（OAuth 用户不需要密码）
          user.password = SecureRandom.hex

          # 保存用户
          user.save!

          # 创建 EmailToken（标记邮箱已验证）
          user.email_tokens.create!(
            email: user.email,
            confirmed: true,
            scope: EmailToken.scopes[:signup]
          )

          # 激活用户
          user.activate

          Rails.logger.info "DingTalk: User created successfully - #{user.username} (ID: #{user.id})"

          # 设置 result.user，这样就不会跳转到注册页面
          result.user = user

          # 更新 UserAssociatedAccount 关联（父类 super 已经创建了，这里只需要关联到新用户）
          association = UserAssociatedAccount.find_by(
            provider_name: "dingtalk",
            provider_uid: uid
          )
          if association
            association.user = user
            association.save!
          else
            Rails.logger.warn "DingTalk: UserAssociatedAccount not found, creating new one"
            UserAssociatedAccount.create!(
              provider_name: "dingtalk",
              provider_uid: uid,
              user: user,
              info: data,
              credentials: auth_token[:credentials] || {},
              extra: extra,
              last_used: Time.zone.now
            )
          end

          # 调用 after_create_account 来设置自定义字段
          after_create_account(user, result)
        end

      rescue ActiveRecord::RecordNotUnique => e
        # Handle race condition: user was created by concurrent request
        Rails.logger.warn "DingTalk: User already exists (race condition), attempting to find - #{e.message}"
        existing_user = User.find_by(email: result.email) || User.find_by(username: username)
        if existing_user
          result.user = existing_user
          Rails.logger.info "DingTalk: Found existing user - #{existing_user.username} (ID: #{existing_user.id})"
        else
          result.failed = true
          result.failed_reason = I18n.t("login.dingtalk.error")
        end
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "DingTalk: Failed to create user - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        result.failed = true
        result.failed_reason = e.record.errors.full_messages.join(", ")
        return result
      rescue StandardError => e
        Rails.logger.error "DingTalk: Unexpected error creating user - #{e.class}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        result.failed = true
        result.failed_reason = I18n.t("login.dingtalk.error")
        return result
      end
    end

    # 🆕 多组织支持：记录用户的企业关联关系
    if result.user.present?
      track_organization_association(
        user: result.user,
        union_id: uid,
        corp_id: auth_token.dig(:extra, :corp_id),
        open_id: extra["openId"]
      )
    end

    # Handle email conflicts
    if SiteSetting.dingtalk_overrides_email && result.email.present?
      result.skip_email_validation = true
    end

    # Log authentication for debugging
    if SiteSetting.dingtalk_debug_auth
      elapsed = ((Time.current - start_time) * 1000).round(2)  # Duration in milliseconds
      Rails.logger.info "DingTalk auth result: user_id=#{result.user&.id}, username=#{result.username}, email=#{result.email}, email_valid=#{result.email_valid}, elapsed=#{elapsed}ms"
    end

    result
  rescue Timeout::Error, Faraday::TimeoutError => e
    elapsed = ((Time.current - start_time) * 1000).round(2) rescue 0
    Rails.logger.error "DingTalk authentication timeout: #{e.class} - #{e.message} (elapsed: #{elapsed}ms)\n#{e.backtrace.join("\n")}"
    result = Auth::Result.new
    result.failed = true
    result.failed_reason = I18n.t("login.dingtalk.timeout_error")
    result
  rescue StandardError => e
    elapsed = ((Time.current - start_time) * 1000).round(2) rescue 0
    Rails.logger.error "DingTalk authentication error: #{e.class} - #{e.message} (elapsed: #{elapsed}ms)\n#{e.backtrace.join("\n")}"
    result = Auth::Result.new
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

    Rails.logger.info "DingTalk: after_create_account completed for #{user.username} (Union ID: #{data[:dingtalk_union_id]})"
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
      # 从 info (JSON) 中获取全名
      info_data = info.info.is_a?(Hash) ? info.info : JSON.parse(info.info)
      full_name = info_data["name"] || info_data["nickname"] || ""

      # 从 extra (JSON) 中获取 unionId
      extra_data = info.extra.is_a?(Hash) ? info.extra : JSON.parse(info.extra)

      # 尝试多个路径获取 unionId
      union_id = extra_data.dig("raw_info", "unionId") ||
                 extra_data["unionId"] ||
                 extra_data["dingtalk_union_id"] || ""

      # 脱敏处理 unionId（类似邮箱格式：显示前3后3，中间省略号）
      obfuscated_union_id = obfuscate_union_id(union_id)

      # 返回格式：全名_$unionid
      if full_name.present? && obfuscated_union_id.present?
        "#{full_name}_$#{obfuscated_union_id}"
      else
        I18n.t("login.dingtalk.connected")
      end
    rescue JSON::ParserError, StandardError => e
      Rails.logger.warn "DingTalk: Failed to parse association data for user #{user.id}: #{e.message}"
      I18n.t("login.dingtalk.connected")
    end
  end

  private

  # 记录用户的企业关联关系（多组织支持）
  # @param user [User] Discourse 用户对象
  # @param union_id [String] 钉钉 UnionID
  # @param corp_id [String] 钉钉企业ID
  # @param open_id [String] 钉钉 OpenID（企业内唯一）
  def track_organization_association(user:, union_id:, corp_id:, open_id:)
    return unless SiteSetting.dingtalk_track_organizations
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

  # 检查企业是否被允许访问（企业访问控制）
  # @param corp_id [String] 钉钉企业ID
  # @return [Boolean]
  def is_organization_allowed?(corp_id)
    return true unless SiteSetting.dingtalk_track_organizations

    # 检查黑名单
    blocked = SiteSetting.dingtalk_blocked_corp_ids.split("|").map(&:strip).reject(&:blank?)
    return false if blocked.include?(corp_id)

    # 检查白名单 (如果配置了)
    allowed = SiteSetting.dingtalk_allowed_corp_ids.split("|").map(&:strip).reject(&:blank?)
    return true if allowed.empty? # 未配置白名单=允许所有

    allowed.include?(corp_id)
  end

  # 脱敏处理 unionId（类似邮箱格式）
  def obfuscate_union_id(union_id)
    return "" if union_id.blank?

    # 显示前3个和后3个字符，中间用...代替
    if union_id.length <= 8
      union_id # 太短直接显示
    else
      "#{union_id[0...3]}...#{union_id[-3..]}"
    end
  end

  # 检测是否为虚拟邮箱
  def virtual_email?(email)
    return false if email.blank?

    email.end_with?("@#{SiteSetting.dingtalk_virtual_email_domain}") ||
      email.end_with?("@#{SiteSetting.dingtalk_mobile_email_domain}")
  end

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
  def generate_username_from_template(uid, data = {}, extra = {})
    template = SiteSetting.dingtalk_username_template

    # 计算 UnionID 的 MD5 hash
    hash_full = Digest::MD5.hexdigest(uid)

    # 获取姓名（保留原始值用于模板替换，优先级：data[:name] > data[:nickname] > extra["nick"]）
    name = data[:name] || data[:nickname] || extra["nick"] || ""

    # 替换模板变量
    uid_truncated = safe_truncate_uid(uid, 16)
    # {姓名} 取值逻辑：与"全名"保持一致（data[:name] > extra["nick"] > data[:nickname]）
    real_name = data[:name].presence || extra["nick"].presence || data[:nickname].presence || "dingtalk_#{hash_full[0..5]}"
    username = template
      .gsub("{hash6}", hash_full[0..5])
      .gsub("{hash8}", hash_full[0..7])
      .gsub("{unionid}", uid_truncated)
      .gsub("{name}", name.presence || "user")  # {name} 经过清洗，有后备值
      .gsub("{姓名}", real_name)  # {姓名} 与"全名"使用相同取值逻辑

    username = username.downcase

    # 验证生成的用户名，如果无效则使用后备方案
    sanitized_result = UserNameSuggester.fix_username(username)
    if sanitized_result.blank?
      # 后备方案：使用 dingtalk_ + hash6
      username = "dingtalk_#{hash_full[0..5]}"
      Rails.logger.warn "DingTalk: Template generated invalid username, using fallback: #{username}"
    else
      username = sanitized_result
    end

    username
  end
end
