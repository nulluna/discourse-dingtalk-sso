# frozen_string_literal: true

require "rails_helper"

describe "DingTalk OAuth Authentication" do
  before do
    SiteSetting.dingtalk_enabled = true
    SiteSetting.dingtalk_client_id = "test_client_id"
    SiteSetting.dingtalk_client_secret = "test_client_secret"

    OmniAuth.config.test_mode = true
  end

  after do
    OmniAuth.config.test_mode = false
  end

  let(:mock_auth) do
    OmniAuth::AuthHash.new(
      provider: "dingtalk",
      uid: "union_test_user",
      info: {
        name: "Test User",
        email: "testuser@example.com",
        nickname: "testuser",
        phone: "13800138000"
      },
      extra: {
        raw_info: {
          "unionId" => "union_test_user",
          "openId" => "open_test",
          "nick" => "Test User",
          "email" => "testuser@example.com",
          "mobile" => "13800138000"
        },
        corp_id: "ding_test_corp"
      }
    )
  end

  describe "GET /auth/dingtalk" do
    it "redirects to DingTalk OAuth authorization" do
      get "/auth/dingtalk"
      expect(response.status).to eq(302)
      expect(response.location).to include("login.dingtalk.com")
    end
  end

  describe "GET /auth/dingtalk/callback" do
    before do
      OmniAuth.config.mock_auth[:dingtalk] = mock_auth
      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:dingtalk]
    end

    context "when user does not exist" do
      it "creates a new user" do
        expect {
          get "/auth/dingtalk/callback"
        }.to change { User.count }.by(1)
      end

      it "creates user with correct attributes" do
        get "/auth/dingtalk/callback"

        user = User.last
        expect(user.email).to eq("testuser@example.com")
        expect(user.username).to eq("testuser")
        expect(user.name).to eq("Test User")
      end

      it "creates UserAssociatedAccount" do
        expect {
          get "/auth/dingtalk/callback"
        }.to change { UserAssociatedAccount.count }.by(1)

        account = UserAssociatedAccount.last
        expect(account.provider_name).to eq("dingtalk")
        expect(account.provider_uid).to eq("union_test_user")
      end

      it "stores extra data in UserAssociatedAccount" do
        get "/auth/dingtalk/callback"

        account = UserAssociatedAccount.last
        extra_data = JSON.parse(account.extra)

        expect(extra_data["dingtalk_union_id"]).to eq("union_test_user")
        expect(extra_data["dingtalk_open_id"]).to eq("open_test")
        expect(extra_data["dingtalk_corp_id"]).to eq("ding_test_corp")
      end

      it "redirects to homepage after successful authentication" do
        get "/auth/dingtalk/callback"
        expect(response).to redirect_to("/")
      end
    end

    context "when user already exists with same email" do
      let!(:existing_user) do
        Fabricate(:user, email: "testuser@example.com")
      end

      it "does not create a new user" do
        expect {
          get "/auth/dingtalk/callback"
        }.not_to change { User.count }
      end

      it "associates DingTalk account with existing user" do
        get "/auth/dingtalk/callback"

        account = UserAssociatedAccount.find_by(
          provider_name: "dingtalk",
          user_id: existing_user.id
        )

        expect(account).to be_present
        expect(account.provider_uid).to eq("union_test_user")
      end
    end

    context "when authentication fails" do
      before do
        OmniAuth.config.mock_auth[:dingtalk] = :invalid_credentials
        Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:dingtalk]
      end

      it "handles failure gracefully" do
        get "/auth/dingtalk/callback"
        expect(response).to redirect_to("/")
      end
    end
  end

  describe "POST /auth/dingtalk/revoke" do
    let(:user) { Fabricate(:user) }

    before do
      sign_in(user)

      UserAssociatedAccount.create!(
        provider_name: "dingtalk",
        user_id: user.id,
        provider_uid: "union_test",
        extra: {
          dingtalk_union_id: "union_test"
        }.to_json
      )
    end

    it "revokes DingTalk authentication" do
      expect {
        post "/associate/dingtalk/revoke"
      }.to change {
        UserAssociatedAccount.where(
          provider_name: "dingtalk",
          user_id: user.id
        ).count
      }.by(-1)
    end
  end
end
