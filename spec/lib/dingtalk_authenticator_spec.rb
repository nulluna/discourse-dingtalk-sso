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
        expect(result.username).to match(/^dingtalk_union_abc123/)
      end
    end

    context "when username is empty" do
      before do
        auth_hash[:info][:nickname] = nil
        auth_hash[:info][:name] = nil
      end

      it "generates username from uid" do
        result = authenticator.after_authenticate(auth_hash)
        expect(result.username).to match(/^dingtalk_union_abc123/)
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

    context "virtual email generation" do
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
          expect(result.email_valid).to be false
          expect(result.failed).to be_falsey
        end
      end

      context "when user has neither email nor mobile" do
        before do
          auth_hash[:info][:email] = nil
          auth_hash[:info][:phone] = nil
        end

        it "generates unionId-based virtual email" do
          result = authenticator.after_authenticate(auth_hash)
          expect(result.email).to match(/^dingtalk_union_abc123de@test\.local$/)
          expect(result.email_valid).to be false
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

    context "username generation from template" do
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
        expect(Rails.logger).to receive(:info).with(/DingTalk auth result/)
        authenticator.after_authenticate(auth_hash)
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

    it "stores union_id mapping in PluginStore" do
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

    it "removes PluginStore data" do
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
