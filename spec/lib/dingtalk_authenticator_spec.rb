# frozen_string_literal: true

require "rails_helper"

describe DingtalkAuthenticator do
  let(:authenticator) { described_class.new }
  let(:auth_hash) do
    OmniAuth::AuthHash.new(
      provider: "dingtalk",
      uid: "union_abc123def456",
      info: {
        name: "张三",
        email: "zhangsan@example.com",
        nickname: "zhangsan",
        phone: "13800138000"
      },
      extra: {
        raw_info: {
          "unionId" => "union_abc123def456",
          "openId" => "open_xyz789",
          "nick" => "张三",
          "email" => "zhangsan@example.com",
          "mobile" => "13800138000"
        },
        corp_id: "ding123456789"
      }
    )
  end

  before do
    SiteSetting.dingtalk_enabled = true
    SiteSetting.dingtalk_client_id = "test_client_id"
    SiteSetting.dingtalk_client_secret = "test_client_secret"
  end

  describe "#name" do
    it "returns correct provider name" do
      expect(authenticator.name).to eq("dingtalk")
    end
  end

  describe "#enabled?" do
    context "when setting is enabled" do
      it "returns true" do
        expect(authenticator.enabled?).to be true
      end
    end

    context "when setting is disabled" do
      before { SiteSetting.dingtalk_enabled = false }

      it "returns false" do
        expect(authenticator.enabled?).to be false
      end
    end
  end

  describe "#can_revoke?" do
    it "returns true" do
      expect(authenticator.can_revoke?).to be true
    end
  end

  describe "#can_connect_existing_user?" do
    it "returns true" do
      expect(authenticator.can_connect_existing_user?).to be true
    end
  end

  describe "#authorize_new_users?" do
    context "when dingtalk_authorize_signup is true" do
      before { SiteSetting.dingtalk_authorize_signup = true }

      it "returns true" do
        expect(authenticator.authorize_new_users?).to be true
      end
    end

    context "when dingtalk_authorize_signup is false" do
      before { SiteSetting.dingtalk_authorize_signup = false }

      it "returns false" do
        expect(authenticator.authorize_new_users?).to be false
      end
    end
  end

  describe "#always_update_user_email?" do
    context "when dingtalk_overrides_email is true" do
      before { SiteSetting.dingtalk_overrides_email = true }

      it "returns true" do
        expect(authenticator.always_update_user_email?).to be true
      end
    end

    context "when dingtalk_overrides_email is false" do
      before { SiteSetting.dingtalk_overrides_email = false }

      it "returns false" do
        expect(authenticator.always_update_user_email?).to be false
      end
    end
  end

  describe "#primary_email_verified?" do
    context "when email is present" do
      it "returns true" do
        expect(authenticator.primary_email_verified?(auth_hash)).to be true
      end
    end

    context "when email is missing" do
      before { auth_hash[:info][:email] = nil }

      it "returns false" do
        expect(authenticator.primary_email_verified?(auth_hash)).to be false
      end
    end
  end

  describe "#after_authenticate" do
    it "returns correct user attributes" do
      result = authenticator.after_authenticate(auth_hash)

      expect(result.username).to eq("zhangsan")
      expect(result.name).to eq("张三")
      expect(result.email).to eq("zhangsan@example.com")
      expect(result.email_valid).to be true
      expect(result.failed).to be_falsey
    end

    it "stores DingTalk-specific extra data" do
      result = authenticator.after_authenticate(auth_hash)

      expect(result.extra_data[:dingtalk_union_id]).to eq("union_abc123def456")
      expect(result.extra_data[:dingtalk_open_id]).to eq("open_xyz789")
      expect(result.extra_data[:dingtalk_corp_id]).to eq("ding123456789")
      expect(result.extra_data[:dingtalk_mobile]).to eq("13800138000")
    end

    context "when username contains special characters" do
      before { auth_hash[:info][:nickname] = "zhang@san#123" }

      it "sanitizes username" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.username).to eq("zhang_san_123")
      end
    end

    context "when username is Chinese" do
      before { auth_hash[:info][:nickname] = "张三" }

      it "generates fallback username from uid" do
        result = authenticator.after_authenticate(auth_hash)
        # Default template is "dingtalk_{hash6}"
        expect(result.username).to match(/^dingtalk_[a-f0-9]{6}$/)
      end
    end

    context "when username is empty" do
      before do
        auth_hash[:info][:nickname] = nil
        auth_hash[:info][:name] = nil
      end

      it "generates username from uid" do
        result = authenticator.after_authenticate(auth_hash)
        # Default template is "dingtalk_{hash6}"
        expect(result.username).to match(/^dingtalk_[a-f0-9]{6}$/)
      end
    end

    context "when username is too short" do
      before { auth_hash[:info][:nickname] = "ab" }

      it "pads username to minimum length" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.username.length).to be >= 3
      end
    end

    context "when username is too long" do
      before { auth_hash[:info][:nickname] = "a" * 30 }

      it "truncates username to maximum length" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.username.length).to be <= 20
      end
    end

    context "when generating virtual email" do
      before do
        SiteSetting.dingtalk_allow_virtual_email = true
        SiteSetting.dingtalk_virtual_email_domain = "test.local"
      end

      context "when user has real email" do
        it "uses real email and marks as valid" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.email).to eq("zhangsan@example.com")
          expect(result.email_valid).to be true
          expect(result.failed).to be_falsey
        end
      end

      context "when user has no email but has mobile" do
        before do
          auth_hash[:info][:email] = nil
          auth_hash[:info][:phone] = "13800138000"
        end

        it "generates mobile-based virtual email" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.email).to eq("13800138000@dingtalk.mobile")
          expect(result.email_valid).to be true # SSO 已验证身份，信任所有邮箱
          expect(result.failed).to be_falsey
        end
      end

      context "when user has neither email nor mobile" do
        before do
          auth_hash[:info][:email] = nil
          auth_hash[:info][:phone] = nil
          auth_hash[:extra][:raw_info]["email"] = nil
          auth_hash[:extra][:raw_info]["mobile"] = nil
        end

        it "generates unionId-based virtual email" do
          result = authenticator.after_authenticate(auth_hash)
          # uid is truncated to 16 chars: "union_abc123def4"
          expect(result.email).to match(/^dingtalk_union_abc123def4@test\.local$/)
          expect(result.email_valid).to be true # SSO 已验证身份，信任所有邮箱
          expect(result.failed).to be_falsey
        end

        it "uses configured domain" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.email).to end_with("@test.local")
        end
      end

      context "when virtual email is disabled" do
        before do
          SiteSetting.dingtalk_allow_virtual_email = false
          auth_hash[:info][:email] = nil
        end

        it "fails authentication for users without email" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.failed).to be true
        end
      end
    end

    context "when generating username from template" do
      before do
        SiteSetting.dingtalk_allow_virtual_email = true
        auth_hash[:info][:nickname] = nil
        auth_hash[:info][:name] = nil
      end

      context "with default template dingtalk_{hash6}" do
        before { SiteSetting.dingtalk_username_template = "dingtalk_{hash6}" }

        it "generates username with 6-char hash" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.username).to match(/^dingtalk_[a-f0-9]{6}$/)
        end

        it "produces consistent hash for same unionId" do
          result1 = authenticator.after_authenticate(auth_hash)
          result2 = authenticator.after_authenticate(auth_hash)
          expect(result1.username).to eq(result2.username)
        end
      end

      context "with name template {name}_{hash6}" do
        before do
          SiteSetting.dingtalk_username_template = "{name}_{hash6}"
          auth_hash[:info][:name] = "Zhang San"
        end

        it "uses sanitized name in username" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.username).to match(/^zhang_san_[a-f0-9]{6}$/)
        end
      end

      context "with Chinese name in template" do
        before do
          SiteSetting.dingtalk_username_template = "dt_{name}"
          auth_hash[:info][:name] = "张三"
          auth_hash[:info][:nickname] = nil
        end

        it "preserves Chinese name in result.name field" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.name).to eq("张三")
        end

        it "generates valid username after sanitization" do
          result = authenticator.after_authenticate(auth_hash)
          # Chinese characters will be sanitized, triggering fallback
          expect(result.username).to be_present
          expect(result.username).to match(/^[a-z0-9_\-]+$/)
        end
      end

      context "with {hash8} template" do
        before { SiteSetting.dingtalk_username_template = "dt_{hash8}" }

        it "generates username with 8-char hash" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.username).to match(/^dt_[a-f0-9]{8}$/)
        end
      end

      context "when dingtalk nickname exists and can be sanitized" do
        before do
          auth_hash[:info][:nickname] = "valid_nick"
          SiteSetting.dingtalk_username_template = "dingtalk_{hash6}"
        end

        it "prefers sanitized nickname over template" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.username).to eq("valid_nick")
        end
      end
    end

    context "when uid is missing" do
      before { auth_hash[:uid] = nil }

      it "fails authentication" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.failed).to be true
      end
    end

    context "when auth_hash is invalid" do
      it "handles nil auth_hash" do
        result = authenticator.after_authenticate(nil)
        expect(result.failed).to be true
      end

      it "handles empty hash" do
        result = authenticator.after_authenticate({})
        expect(result.failed).to be true
      end

      it "handles malformed data" do
        result = authenticator.after_authenticate({ info: "invalid" })
        expect(result.failed).to be true
      end
    end

    context "when dingtalk_overrides_email is enabled" do
      before { SiteSetting.dingtalk_overrides_email = true }

      it "sets skip_email_validation flag" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.skip_email_validation).to be true
      end
    end

    context "with debug mode enabled" do
      before { SiteSetting.dingtalk_debug_auth = true }

      it "logs authentication details" do
        allow(Rails.logger).to receive(:info)
        authenticator.after_authenticate(auth_hash)
        expect(Rails.logger).to have_received(:info).with(/DingTalk auth result/).at_least(:once)
      end
    end

    # 🔥 新增：SSO 自动登录测试（关键修复验证）
    context "when auto-creating new user for SSO login" do
      before do
        SiteSetting.dingtalk_authorize_signup = true
        # 确保没有同名用户（使用 Discourse 的 find_by_email）
        existing_user = User.find_by_email(auth_hash[:info][:email])
        existing_user.destroy! if existing_user
        UserAssociatedAccount.where(provider_name: "dingtalk", provider_uid: auth_hash[:uid]).destroy_all
      end

      it "creates new user automatically when user does not exist" do
        expect {
          result = authenticator.after_authenticate(auth_hash)
          expect(result.user).to be_present
          expect(result.user.persisted?).to be true
        }.to change { User.count }.by(1)
      end

      it "sets result.user to prevent redirect to signup page" do
        result = authenticator.after_authenticate(auth_hash)

        expect(result.user).to be_present
        expect(result.user).to be_a(User)
        expect(result.failed).to be_falsey
      end

      it "activates user immediately" do
        result = authenticator.after_authenticate(auth_hash)

        expect(result.user.active).to be true
        expect(result.user.approved?).to be true
      end

      it "creates confirmed EmailToken for the user" do
        result = authenticator.after_authenticate(auth_hash)

        email_token = result.user.email_tokens.find_by(email: result.user.email)
        expect(email_token).to be_present
        expect(email_token.confirmed).to be true
      end

      it "creates UserAssociatedAccount with correct provider_uid" do
        result = authenticator.after_authenticate(auth_hash)

        association = UserAssociatedAccount.find_by(
          provider_name: "dingtalk",
          provider_uid: auth_hash[:uid],
          user_id: result.user.id
        )
        expect(association).to be_present
        expect(association.last_used).to be_present
      end

      it "sets user email from auth_hash" do
        result = authenticator.after_authenticate(auth_hash)

        expect(result.user.email).to eq("zhangsan@example.com")
      end

      it "sets user name from auth_hash" do
        result = authenticator.after_authenticate(auth_hash)

        expect(result.user.name).to eq("张三")
      end

      it "generates valid username" do
        result = authenticator.after_authenticate(auth_hash)

        expect(result.user.username).to be_present
        expect(result.user.username).to match(/^[a-z0-9_\-]+$/)
      end

      context "with virtual email user" do
        before do
          SiteSetting.dingtalk_allow_virtual_email = true
          auth_hash[:info][:email] = nil
          auth_hash[:info][:phone] = "13800138000"
        end

        it "creates user with virtual email and activates" do
          result = authenticator.after_authenticate(auth_hash)

          expect(result.user).to be_present
          expect(result.user.email).to eq("13800138000@dingtalk.mobile")
          expect(result.user.active).to be true
        end
      end

      context "when dingtalk_authorize_signup is false" do
        before { SiteSetting.dingtalk_authorize_signup = false }

        it "does not create user automatically" do
          expect {
            result = authenticator.after_authenticate(auth_hash)
            expect(result.user).to be_nil
          }.not_to change { User.count }
        end
      end

      context "when user already exists (by email)" do
        let!(:existing_user) { Fabricate(:user, email: "zhangsan@example.com") }

        it "finds existing user instead of creating new one" do
          expect {
            result = authenticator.after_authenticate(auth_hash)
            expect(result.user).to eq(existing_user)
          }.not_to change { User.count }
        end

        it "does not fail authentication" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.failed).to be_falsey
        end
      end
    end
  end

  describe "#after_create_account" do
    let(:user) { Fabricate(:user) }
    let(:auth) do
      {
        extra_data: {
          dingtalk_union_id: "union_test123",
          dingtalk_mobile: "13800138000"
        }
      }
    end

    xit "stores union_id mapping in PluginStore" do
      # NOTE: PluginStore functionality not currently implemented
      # UserAssociatedAccount already provides union_id mapping
      authenticator.after_create_account(user, auth)

      stored_data = ::PluginStore.get(
        "dingtalk_sso",
        "dingtalk_union_id_union_test123"
      )

      expect(stored_data[:user_id]).to eq(user.id)
    end

    it "saves mobile number as custom field" do
      authenticator.after_create_account(user, auth)
      user.reload

      expect(user.custom_fields["dingtalk_mobile"]).to eq("13800138000")
    end

    # Note: Virtual email user activation is now handled in after_authenticate
    # when auto-creating users, not in after_create_account
  end

  describe "#revoke" do
    let(:user) { Fabricate(:user) }

    before do
      UserAssociatedAccount.create!(
        provider_name: "dingtalk",
        user_id: user.id,
        provider_uid: "union_test123",
        extra: {
          dingtalk_union_id: "union_test123"
        }.to_json
      )

      ::PluginStore.set(
        "dingtalk_sso",
        "dingtalk_union_id_union_test123",
        { user_id: user.id }
      )

      user.custom_fields["dingtalk_mobile"] = "13800138000"
      user.save_custom_fields
    end

    it "removes UserAssociatedAccount" do
      expect {
        authenticator.revoke(user)
      }.to change { UserAssociatedAccount.count }.by(-1)
    end

    xit "removes PluginStore data" do
      # NOTE: PluginStore functionality not currently implemented
      authenticator.revoke(user)

      stored_data = ::PluginStore.get(
        "dingtalk_sso",
        "dingtalk_union_id_union_test123"
      )

      expect(stored_data).to be_nil
    end

    it "removes custom fields" do
      authenticator.revoke(user)
      user.reload

      expect(user.custom_fields["dingtalk_mobile"]).to be_nil
    end

    it "returns true" do
      expect(authenticator.revoke(user)).to be true
    end
  end

  describe "#description_for_user" do
    let(:user) { Fabricate(:user) }

    before do
      UserAssociatedAccount.create!(
        provider_name: "dingtalk",
        user_id: user.id,
        provider_uid: "union_test123",
        extra: {
          dingtalk_union_id: "union_test123"
        }.to_json
      )
    end

    it "returns formatted description" do
      description = authenticator.description_for_user(user)
      expect(description).to include("union_test123")
    end
  end
end
