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

  def primary_email_verified?(auth_token)
    # DingTalk emails from enterprise apps are considered verified
    auth_token.dig(:info, :email).present?
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

    # Validate required fields
    unless auth_token[:uid].present?
      Rails.logger.error "DingTalk: Missing unionId/uid"
      result.failed = true
      result.failed_reason = I18n.t("login.dingtalk.error")
      return result
    end

    # Set basic user attributes
    username_candidate = data[:nickname] || data[:name] || extra["nick"]
    result.username = sanitize_username(username_candidate)

    # Fallback to uid-based username if sanitization fails
    if result.username.blank?
      result.username = "dingtalk_#{auth_token[:uid][0..15]}"
      Rails.logger.warn "DingTalk: Generated fallback username: #{result.username}"
    end

    result.name = data[:name] || data[:nickname] || result.username
    result.email = data[:email]
    result.email_valid = data[:email].present?

    # Validate email requirement
    unless result.email.present?
      Rails.logger.error "DingTalk: Missing email for user #{result.username}"
      result.failed = true
      result.failed_reason = I18n.t("login.dingtalk.missing_email")
      return result
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
      Rails.logger.info "DingTalk auth result: username=#{result.username}, email=#{result.email}, uid=#{auth_token[:uid]}"
    end

    result
  rescue StandardError => e
    Rails.logger.error "DingTalk authentication error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
    result.failed = true
    result.failed_reason = I18n.t("login.dingtalk.error")
    result
  end

  def after_create_account(user, auth)
    # Store mapping between DingTalk unionId and Discourse user
    data = auth[:extra_data]

    ::PluginStore.set(
      "dingtalk_sso",
      "dingtalk_union_id_#{data[:dingtalk_union_id]}",
      { user_id: user.id, created_at: Time.now }
    )

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
      extra_data = JSON.parse(authenticator.extra) rescue {}
      union_id = extra_data["dingtalk_union_id"]

      if union_id.present?
        ::PluginStore.remove("dingtalk_sso", "dingtalk_union_id_#{union_id}")
      end

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

    extra_data = JSON.parse(info.extra) rescue {}
    union_id = extra_data["dingtalk_union_id"]

    I18n.t("login.dingtalk.description", union_id: union_id)
  end

  private

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
      .gsub(/^_+|_+$/, "")
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

    # Ensure minimum length (min 3 chars)
    while sanitized.length < 3
      sanitized += "_"
    end

    # Return empty if still invalid after all processing
    sanitized =~ /^[a-z0-9][a-z0-9_\-]{1,18}[a-z0-9]$/i ? sanitized : ""
  end
end
