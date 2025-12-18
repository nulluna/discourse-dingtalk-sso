# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/omniauth/strategies/dingtalk"

describe OmniAuth::Strategies::Dingtalk do
  let(:app) do
    lambda { |_env| [200, {}, ["Hello"]] }
  end

  let(:strategy) do
    OmniAuth::Strategies::Dingtalk.new(app, "client_id", "client_secret")
  end

  describe "#client_options" do
    it "has correct site" do
      expect(strategy.options.client_options.site).to eq("https://api.dingtalk.com")
    end

    it "has correct authorize_url" do
      expect(strategy.options.client_options.authorize_url).to eq("https://login.dingtalk.com/oauth2/auth")
    end

    it "has correct token_url" do
      expect(strategy.options.client_options.token_url).to eq("https://api.dingtalk.com/v1.0/oauth2/userAccessToken")
    end
  end

  describe "#uid" do
    before do
      allow(strategy).to receive(:raw_info).and_return(
        "unionId" => "test_union_id",
        "openId" => "test_open_id"
      )
    end

    it "returns unionId as uid" do
      expect(strategy.uid).to eq("test_union_id")
    end

    context "when unionId is missing" do
      before do
        allow(strategy).to receive(:raw_info).and_return(
          "openId" => "test_open_id"
        )
      end

      it "falls back to openId" do
        expect(strategy.uid).to eq("test_open_id")
      end
    end
  end

  describe "#info" do
    let(:user_data) do
      {
        "nick" => "Test User",
        "email" => "test@example.com",
        "mobile" => "13800138000"
      }
    end

    before do
      allow(strategy).to receive(:raw_info).and_return(user_data)
    end

    it "returns user info hash" do
      info = strategy.info

      expect(info[:name]).to eq("Test User")
      expect(info[:email]).to eq("test@example.com")
      expect(info[:phone]).to eq("13800138000")
      expect(info[:nickname]).to eq("Test User")
    end

    context "when nick is missing" do
      before do
        user_data.delete("nick")
        user_data["name"] = "Fallback Name"
      end

      it "falls back to name field" do
        expect(strategy.info[:name]).to eq("Fallback Name")
        expect(strategy.info[:nickname]).to eq("Fallback Name")
      end
    end

    context "when all fields are missing" do
      before do
        allow(strategy).to receive(:raw_info).and_return({})
      end

      it "returns nil values" do
        info = strategy.info
        expect(info[:name]).to be_nil
        expect(info[:email]).to be_nil
        expect(info[:phone]).to be_nil
      end
    end
  end

  describe "#extra" do
    let(:raw_data) do
      {
        "unionId" => "test_union",
        "openId" => "test_open",
        "nick" => "Test"
      }
    end

    before do
      allow(strategy).to receive(:raw_info).and_return(raw_data)
      allow(strategy).to receive(:access_token).and_return(
        double(params: { "corpId" => "test_corp" })
      )
    end

    it "includes raw_info" do
      expect(strategy.extra[:raw_info]).to eq(raw_data)
    end

    it "includes corp_id" do
      expect(strategy.extra[:corp_id]).to eq("test_corp")
    end

    context "when corpId uses underscore format" do
      before do
        allow(strategy).to receive(:access_token).and_return(
          double(params: { "corp_id" => "test_corp_underscore" })
        )
      end

      it "falls back to corp_id" do
        expect(strategy.extra[:corp_id]).to eq("test_corp_underscore")
      end
    end
  end

  describe "#raw_info" do
    let(:access_token) { double("access_token") }
    let(:response) { double("response") }

    before do
      allow(strategy).to receive(:access_token).and_return(access_token)
      allow(access_token).to receive(:token).and_return("test_token")
    end

    context "with successful response" do
      before do
        allow(access_token).to receive(:get).and_return(response)
        allow(response).to receive(:body).and_return('{"nick":"Test","email":"test@example.com"}')
      end

      it "fetches and parses user info" do
        info = strategy.send(:raw_info)
        expect(info["nick"]).to eq("Test")
        expect(info["email"]).to eq("test@example.com")
      end
    end

    context "with DingTalk API error" do
      before do
        allow(access_token).to receive(:get).and_return(response)
        allow(response).to receive(:body).and_return('{"errcode":40014,"errmsg":"invalid access token"}')
      end

      it "returns empty hash and logs error" do
        expect(strategy).to receive(:log_error).with(/DingTalk API error/)
        info = strategy.send(:raw_info)
        expect(info).to eq({})
      end
    end

    context "with OAuth error" do
      before do
        allow(access_token).to receive(:get).and_raise(OAuth2::Error.new(response))
      end

      it "returns empty hash and logs error" do
        expect(strategy).to receive(:log_error).with(/user info OAuth error/)
        info = strategy.send(:raw_info)
        expect(info).to eq({})
      end
    end

    context "with JSON parse error" do
      before do
        allow(access_token).to receive(:get).and_return(response)
        allow(response).to receive(:body).and_return("invalid json")
      end

      it "returns empty hash and logs error" do
        expect(strategy).to receive(:log_error).with(/user info parse error/)
        info = strategy.send(:raw_info)
        expect(info).to eq({})
      end
    end

    context "when access_token is nil" do
      before do
        allow(strategy).to receive(:access_token).and_return(nil)
      end

      it "returns empty hash" do
        info = strategy.send(:raw_info)
        expect(info).to eq({})
      end
    end

    context "when access_token has no token" do
      before do
        allow(access_token).to receive(:token).and_return(nil)
      end

      it "returns empty hash" do
        info = strategy.send(:raw_info)
        expect(info).to eq({})
      end
    end
  end

  describe "#callback_url" do
    it "uses redirect_uri option if set" do
      strategy.options[:redirect_uri] = "https://example.com/callback"
      expect(strategy.callback_url).to eq("https://example.com/callback")
    end

    it "builds callback_url from request if redirect_uri not set" do
      allow(strategy).to receive(:full_host).and_return("https://example.com")
      allow(strategy).to receive(:script_name).and_return("")
      allow(strategy).to receive(:callback_path).and_return("/auth/dingtalk/callback")

      expect(strategy.callback_url).to eq("https://example.com/auth/dingtalk/callback")
    end
  end
end
