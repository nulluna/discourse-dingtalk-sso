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
      before do
        auth_hash[:info][:nickname] = "张三"
        # 确保没有用户名冲突
        User.where("username LIKE 'dingtalk_%' OR username LIKE 'user%'").destroy_all
      end

      it "generates fallback username from uid" do
        result = authenticator.after_authenticate(auth_hash)
        # Default template is "dingtalk_{hash6}" or Discourse's fallback suggestion
        # UserNameSuggester might modify it, so we check it's valid and non-Chinese
        expect(result.username).to be_present
        expect(result.username).to match(/^[a-z0-9_\-]+$/)
        expect(result.username).not_to eq("张三")
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

    # 🔥 测试现有用户主动关联钉钉账号的场景
    context "when connecting existing user account (existing_account parameter)" do
      let!(:existing_user) do
        Fabricate(:user,
          email: "original@example.com",
          username: "originaluser"
        )
      end

      before do
        SiteSetting.dingtalk_authorize_signup = true
        # 确保没有已存在的关联
        UserAssociatedAccount.where(provider_name: "dingtalk", provider_uid: auth_hash[:uid]).destroy_all
      end

      context "when existing user email differs from DingTalk email" do
        it "should connect DingTalk account to existing user without creating new user" do
          expect {
            result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

            # 🔥 关键断言：应该使用现有用户，而不是创建新用户
            expect(result.user).to eq(existing_user)
            expect(result.user.id).to eq(existing_user.id)
            expect(result.failed).to be_falsey
          }.not_to change { User.count }
        end

        it "should create UserAssociatedAccount linking to existing user" do
          result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          association = UserAssociatedAccount.find_by(
            provider_name: "dingtalk",
            provider_uid: auth_hash[:uid]
          )

          expect(association).to be_present
          expect(association.user_id).to eq(existing_user.id)
        end

        it "should not trigger auto-create user logic" do
          # Mock logger to verify auto-create logic is not triggered
          allow(Rails.logger).to receive(:info)

          authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          # 验证没有触发自动创建用户的日志
          expect(Rails.logger).not_to have_received(:info)
            .with(/Creating new user automatically/)
        end
      end

      context "when DingTalk email matches another existing user" do
        let!(:user_with_dingtalk_email) do
          Fabricate(:user, email: "zhangsan@example.com")
        end

        it "should connect to the existing_account user, not the email-matched user" do
          result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          # 应该关联到 existing_user，而不是 user_with_dingtalk_email
          expect(result.user).to eq(existing_user)
          expect(result.user.id).to eq(existing_user.id)

          association = UserAssociatedAccount.find_by(
            provider_name: "dingtalk",
            provider_uid: auth_hash[:uid]
          )
          expect(association.user_id).to eq(existing_user.id)
        end
      end

      context "when using virtual email" do
        before do
          SiteSetting.dingtalk_allow_virtual_email = true
          auth_hash[:info][:email] = nil
          auth_hash[:info][:phone] = "13900000000"
        end

        it "should connect virtual email user to existing account" do
          result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          expect(result.user).to eq(existing_user)
          expect(result.failed).to be_falsey

          # 验证虚拟邮箱被正确生成
          expect(result.email).to eq("13900000000@dingtalk.mobile")
        end
      end

      context "when DingTalk returns email that already exists for another user" do
        let!(:another_user) do
          Fabricate(:user, email: "zhangsan@example.com", username: "zhangsan")
        end

        it "should still connect to existing_account, not fail with duplicate email" do
          result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          # 应该成功关联到 existing_user
          expect(result.user).to eq(existing_user)
          expect(result.failed).to be_falsey

          association = UserAssociatedAccount.find_by(
            provider_name: "dingtalk",
            provider_uid: auth_hash[:uid]
          )
          expect(association.user_id).to eq(existing_user.id)
        end
      end

      context "when DingTalk returns username that already exists" do
        let!(:another_user) do
          Fabricate(:user, username: "zhangsan", email: "another@example.com")
        end

        it "should still connect to existing_account, not fail with duplicate username" do
          result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          # 应该成功关联到 existing_user
          expect(result.user).to eq(existing_user)
          expect(result.failed).to be_falsey

          association = UserAssociatedAccount.find_by(
            provider_name: "dingtalk",
            provider_uid: auth_hash[:uid]
          )
          expect(association.user_id).to eq(existing_user.id)
        end
      end

      # 🔥 这个测试模拟了可能出错的场景：
      # 当 match_by_email 找到的用户与 existing_account 不同时
      context "when ManagedAuthenticator tries to match by email but finds different user" do
        let!(:email_matched_user) do
          Fabricate(:user, email: "zhangsan@example.com", username: "zhangsan_original")
        end

        before do
          # 确保 match_by_email 为 true（这是默认的）
          allow(authenticator).to receive(:match_by_email).and_return(true)
        end

        it "should prioritize existing_account over email-matched user" do
          result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          # 🔥 关键：应该关联到 existing_account，而不是 email_matched_user
          expect(result.user).to eq(existing_user)
          expect(result.user).not_to eq(email_matched_user)
          expect(result.failed).to be_falsey

          association = UserAssociatedAccount.find_by(
            provider_name: "dingtalk",
            provider_uid: auth_hash[:uid]
          )
          expect(association.user_id).to eq(existing_user.id)
        end

        it "should destroy any existing association for the email-matched user" do
          # 先为 email_matched_user 创建一个钉钉关联
          UserAssociatedAccount.create!(
            provider_name: "dingtalk",
            user_id: email_matched_user.id,
            provider_uid: "old_uid_456",
            info: {},
            credentials: {},
            extra: {}
          )

          expect {
            result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)
            expect(result.failed).to be_falsey
          }.to change {
            UserAssociatedAccount.where(
              provider_name: "dingtalk",
              user_id: existing_user.id
            ).count
          }.by(1)
        end
      end

      # 🔥🔥🔥 这个是最关键的测试场景！
      # 当钉钉UID已经被其他用户关联时，尝试关联到existing_account
      context "when the DingTalk UID is already associated with another user" do
        let!(:another_user_with_same_dingtalk) do
          Fabricate(:user, email: "another@example.com", username: "anotheruser")
        end

        before do
          # 另一个用户已经关联了这个钉钉UID
          UserAssociatedAccount.create!(
            provider_name: "dingtalk",
            user_id: another_user_with_same_dingtalk.id,
            provider_uid: auth_hash[:uid],  # ← 相同的钉钉UID！
            info: {},
            credentials: {},
            extra: {}
          )
        end

        it "should reassociate the DingTalk UID to existing_account" do
          result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)

          # 应该关联到 existing_account
          expect(result.user).to eq(existing_user)
          expect(result.failed).to be_falsey

          # 验证关联已经转移到 existing_user
          association = UserAssociatedAccount.find_by(
            provider_name: "dingtalk",
            provider_uid: auth_hash[:uid]
          )
          expect(association.user_id).to eq(existing_user.id)
          expect(association.user_id).not_to eq(another_user_with_same_dingtalk.id)
        end

        it "should not create duplicate UserAssociatedAccount" do
          expect {
            result = authenticator.after_authenticate(auth_hash, existing_account: existing_user)
            expect(result.failed).to be_falsey
          }.not_to change { UserAssociatedAccount.count }
        end
      end
    end

    # 🔥 需求1测试：自动填充用户全名
    context "when auto-filling user name on association" do
      let!(:user_without_name) do
        Fabricate(:user, email: "test@example.com", username: "testuser", name: "")
      end

      before do
        SiteSetting.dingtalk_authorize_signup = true
        UserAssociatedAccount.where(provider_name: "dingtalk", provider_uid: auth_hash[:uid]).destroy_all
      end

      context "when dingtalk_auto_fill_user_name is enabled" do
        before { SiteSetting.dingtalk_auto_fill_user_name = true }

        it "should fill user name when associating DingTalk account" do
          authenticator.after_authenticate(auth_hash, existing_account: user_without_name)

          user_without_name.reload
          expect(user_without_name.name).to eq("张三")
        end

        it "should not override existing name" do
          user_with_name = Fabricate(:user, name: "Original Name", username: "useroriginal")

          authenticator.after_authenticate(auth_hash, existing_account: user_with_name)

          user_with_name.reload
          expect(user_with_name.name).to eq("Original Name")
        end

        it "should log the auto-fill action" do
          allow(Rails.logger).to receive(:info)

          authenticator.after_authenticate(auth_hash, existing_account: user_without_name)

          expect(Rails.logger).to have_received(:info)
            .with(/Auto-filled user name for #{user_without_name.username}/)
        end
      end

      context "when dingtalk_auto_fill_user_name is disabled" do
        before { SiteSetting.dingtalk_auto_fill_user_name = false }

        it "should not fill user name" do
          authenticator.after_authenticate(auth_hash, existing_account: user_without_name)

          user_without_name.reload
          expect(user_without_name.name).to be_blank
        end
      end

      context "when not in association flow (no existing_account)" do
        before { SiteSetting.dingtalk_auto_fill_user_name = true }

        it "should not auto-fill for new user registration" do
          allow(Rails.logger).to receive(:info)

          authenticator.after_authenticate(auth_hash)

          # Should not trigger auto-fill log
          expect(Rails.logger).not_to have_received(:info)
            .with(/Auto-filled user name/)
        end
      end
    end
  end

  describe "#description_for_user" do
    let(:user) { Fabricate(:user) }

    context "when user has DingTalk association with full data" do
      before do
        UserAssociatedAccount.create!(
          provider_name: "dingtalk",
          user_id: user.id,
          provider_uid: "union_abc123def456",
          info: { name: "张三", nickname: "zhangsan" }.to_json,
          extra: { raw_info: { unionId: "union_abc123def456" } }.to_json
        )
      end

      it "should return formatted description with obfuscated unionId" do
        description = authenticator.description_for_user(user)
        expect(description).to eq("张三_$uni...456")
      end
    end

    context "when unionId is in extra root (not in raw_info)" do
      before do
        UserAssociatedAccount.create!(
          provider_name: "dingtalk",
          user_id: user.id,
          provider_uid: "union_xyz789",
          info: { name: "李四" }.to_json,
          extra: { unionId: "union_xyz789" }.to_json
        )
      end

      it "should still find and format unionId correctly" do
        description = authenticator.description_for_user(user)
        expect(description).to eq("李四_$uni...789")
      end
    end

    context "when unionId is short" do
      before do
        UserAssociatedAccount.create!(
          provider_name: "dingtalk",
          user_id: user.id,
          provider_uid: "short",
          info: { name: "王五" }.to_json,
          extra: { raw_info: { unionId: "short" } }.to_json
        )
      end

      it "should not obfuscate short unionId" do
        description = authenticator.description_for_user(user)
        expect(description).to eq("王五_$short")
      end
    end

    context "when name is missing but nickname exists" do
      before do
        UserAssociatedAccount.create!(
          provider_name: "dingtalk",
          user_id: user.id,
          provider_uid: "union_123",
          info: { nickname: "赵六" }.to_json,
          extra: { unionId: "union_abc123" }.to_json
        )
      end

      it "should use nickname as fallback" do
        description = authenticator.description_for_user(user)
        expect(description).to eq("赵六_$uni...123")
      end
    end

    context "when data is missing" do
      before do
        UserAssociatedAccount.create!(
          provider_name: "dingtalk",
          user_id: user.id,
          provider_uid: "union_123",
          info: {}.to_json,
          extra: {}.to_json
        )
      end

      it "should return default connected message" do
        description = authenticator.description_for_user(user)
        expect(description).to eq(I18n.t("login.dingtalk.connected"))
      end
    end

    context "when info/extra are Hash objects (not JSON strings)" do
      before do
        UserAssociatedAccount.create!(
          provider_name: "dingtalk",
          user_id: user.id,
          provider_uid: "union_hash",
          info: { "name" => "Hash测试", "nickname" => "hashtest" },
          extra: { "raw_info" => { "unionId" => "union_hashabc123" } }
        )
      end

      it "should handle Hash format correctly" do
        description = authenticator.description_for_user(user)
        expect(description).to eq("Hash测试_$uni...123")
      end
    end

    context "when no association exists" do
      it "should return empty string" do
        description = authenticator.description_for_user(user)
        expect(description).to eq("")
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

  describe "multi-organization support" do
    before do
      SiteSetting.dingtalk_track_organizations = true
      SiteSetting.dingtalk_authorize_signup = true
    end

    context "when user logs in from first organization" do
      it "creates organization association record" do
        expect {
          authenticator.after_authenticate(auth_hash)
        }.to change { DingtalkUserOrganization.count }.by(1)

        org = DingtalkUserOrganization.last
        expect(org.corp_id).to eq("ding123456789")
        expect(org.union_id).to eq("union_abc123def456")
        expect(org.open_id).to eq("open_xyz789")
      end

      it "records first_login_at and last_login_at" do
        freeze_time do
          result = authenticator.after_authenticate(auth_hash)

          org = DingtalkUserOrganization.find_by(
            user_id: result.user.id,
            corp_id: "ding123456789"
          )

          expect(org.first_login_at).to be_within(1.second).of(Time.zone.now)
          expect(org.last_login_at).to be_within(1.second).of(Time.zone.now)
        end
      end
    end

    context "when same user logs in from different organization" do
      it "creates new organization association but reuses same user account" do
        # First login from corp_A
        auth_hash_corp_a = auth_hash.dup
        auth_hash_corp_a[:extra][:corp_id] = "corp_A"

        result1 = authenticator.after_authenticate(auth_hash_corp_a)
        user_id_1 = result1.user.id

        # Second login from corp_B (same unionId)
        auth_hash_corp_b = auth_hash.dup
        auth_hash_corp_b[:extra][:corp_id] = "corp_B"

        result2 = authenticator.after_authenticate(auth_hash_corp_b)
        user_id_2 = result2.user.id

        # Should map to same user
        expect(user_id_1).to eq(user_id_2)

        # Should have two organization records
        orgs = DingtalkUserOrganization.where(user_id: user_id_1)
        expect(orgs.count).to eq(2)
        expect(orgs.map(&:corp_id)).to contain_exactly("corp_A", "corp_B")
        expect(orgs.map(&:union_id).uniq).to eq(["union_abc123def456"])
      end

      it "updates last_login_at for existing organization on subsequent login" do
        # First login
        result1 = authenticator.after_authenticate(auth_hash)
        org = DingtalkUserOrganization.find_by(
          user_id: result1.user.id,
          corp_id: "ding123456789"
        )
        first_login_time = org.first_login_at
        initial_last_login_time = org.last_login_at

        # Wait and login again
        freeze_time(1.day.from_now)

        result2 = authenticator.after_authenticate(auth_hash)
        org.reload

        # first_login_at should remain unchanged
        expect(org.first_login_at).to eq(first_login_time)

        # last_login_at should be updated
        expect(org.last_login_at).to be > initial_last_login_time
        expect(org.last_login_at).to be_within(1.second).of(Time.zone.now)
      end
    end

    context "when tracking is disabled" do
      before { SiteSetting.dingtalk_track_organizations = false }

      it "does not create organization association" do
        expect {
          authenticator.after_authenticate(auth_hash)
        }.not_to change { DingtalkUserOrganization.count }
      end

      it "still authenticates user successfully" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.user).to be_present
        expect(result.failed).to be_falsey
      end
    end

    context "with organization access control" do
      before do
        SiteSetting.dingtalk_track_organizations = true
      end

      context "when corp_id is in blocked list" do
        before do
          SiteSetting.dingtalk_blocked_corp_ids = "blocked_corp_1|blocked_corp_2"
        end

        it "rejects authentication" do
          auth_hash[:extra][:corp_id] = "blocked_corp_1"
          result = authenticator.after_authenticate(auth_hash)

          expect(result.failed).to be true
          expect(result.failed_reason).to eq(I18n.t("login.dingtalk.organization_not_allowed"))
        end

        it "allows authentication for non-blocked corp" do
          auth_hash[:extra][:corp_id] = "allowed_corp"
          result = authenticator.after_authenticate(auth_hash)

          expect(result.failed).to be_falsey
          expect(result.user).to be_present
        end
      end

      context "when allowlist is configured" do
        before do
          SiteSetting.dingtalk_allowed_corp_ids = "allowed_corp_1|allowed_corp_2"
        end

        it "allows only whitelisted organizations" do
          auth_hash[:extra][:corp_id] = "allowed_corp_1"
          result = authenticator.after_authenticate(auth_hash)

          expect(result.failed).to be_falsey
          expect(result.user).to be_present
        end

        it "rejects non-whitelisted organizations" do
          auth_hash[:extra][:corp_id] = "unknown_corp"
          result = authenticator.after_authenticate(auth_hash)

          expect(result.failed).to be true
          expect(result.failed_reason).to eq(I18n.t("login.dingtalk.organization_not_allowed"))
        end
      end

      context "when both allowlist and blocklist are configured" do
        before do
          SiteSetting.dingtalk_allowed_corp_ids = "corp_A|corp_B"
          SiteSetting.dingtalk_blocked_corp_ids = "corp_B"
        end

        it "blocklist takes precedence over allowlist" do
          auth_hash[:extra][:corp_id] = "corp_B"
          result = authenticator.after_authenticate(auth_hash)

          expect(result.failed).to be true
        end
      end
    end

    context "when corp_id is missing" do
      before do
        auth_hash[:extra][:corp_id] = nil
        SiteSetting.dingtalk_track_organizations = true
      end

      it "does not create organization association" do
        expect {
          authenticator.after_authenticate(auth_hash)
        }.not_to change { DingtalkUserOrganization.count }
      end

      it "still authenticates user successfully" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.user).to be_present
        expect(result.failed).to be_falsey
      end
    end

    context "when organization tracking fails" do
      before do
        SiteSetting.dingtalk_track_organizations = true
        # Simulate database error
        allow(DingtalkUserOrganization).to receive(:find_or_initialize_by).and_raise(ActiveRecord::StatementInvalid.new("Database error"))
      end

      it "logs error but does not block authentication" do
        expect(Rails.logger).to receive(:error).with(/Failed to track org association/)

        result = authenticator.after_authenticate(auth_hash)

        # Authentication should still succeed
        expect(result.user).to be_present
        expect(result.failed).to be_falsey
      end
    end
  end

end
