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

  # Reset concurrency counter between tests
  before do
    OmniAuth::Strategies::Dingtalk.concurrent_count = 0
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

    context "when access_token is nil" do
      before do
        allow(strategy).to receive(:access_token).and_return(nil)
      end

      it "returns nil corp_id without crashing" do
        expect(strategy.extra[:corp_id]).to be_nil
        expect(strategy.extra[:raw_info]).to eq(raw_data)
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

      it "returns empty hash" do
        info = strategy.send(:raw_info)
        expect(info).to eq({})
      end
    end

    context "with OAuth error" do
      before do
        mock_response = double("response").as_null_object
        oauth_error = OAuth2::Error.new(mock_response)
        allow(access_token).to receive(:get).and_raise(oauth_error)
      end

      it "returns empty hash" do
        info = strategy.send(:raw_info)
        expect(info).to eq({})
      end
    end

    context "with JSON parse error" do
      before do
        allow(access_token).to receive(:get).and_return(response)
        allow(response).to receive(:body).and_return("invalid json")
      end

      it "returns empty hash" do
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

  describe "#build_access_token" do
    let(:mock_request) { double("request", params: { "code" => "test_code" }) }
    let(:mock_client) { double("client") }
    let(:mock_connection) { double("connection") }
    let(:mock_options) { double("options") }
    let(:mock_builder) { double("builder", handlers: []) }

    before do
      allow(strategy).to receive(:request).and_return(mock_request)
      allow(strategy).to receive(:client).and_return(mock_client)
      allow(mock_client).to receive(:id).and_return("client_id")
      allow(mock_client).to receive(:secret).and_return("client_secret")
      allow(mock_client).to receive(:connection).and_return(mock_connection)
      allow(mock_connection).to receive(:options).and_return(mock_options)
      allow(mock_connection).to receive(:builder).and_return(mock_builder)
      allow(mock_connection).to receive(:request)
      allow(mock_options).to receive(:timeout=)
      allow(mock_options).to receive(:open_timeout=)
    end

    context "when code is missing" do
      before do
        allow(mock_request).to receive(:params).and_return({})
      end

      it "returns nil without making API call" do
        result = strategy.build_access_token
        expect(result).to be_nil
      end
    end

    context "when connection times out" do
      before do
        allow(mock_client).to receive(:request).and_raise(Faraday::TimeoutError.new("execution expired"))
      end

      it "returns nil (not Rack Array)" do
        result = strategy.build_access_token
        expect(result).to be_nil
        expect(result).not_to be_a(Array)
      end

      it "sets error key to dingtalk_timeout_error" do
        strategy.build_access_token
        expect(strategy.instance_variable_get(:@token_error_key)).to eq(:dingtalk_timeout_error)
      end
    end

    context "when connection fails" do
      before do
        allow(mock_client).to receive(:request).and_raise(
          Faraday::ConnectionFailed.new("Failed to open TCP connection to api.dingtalk.com:443")
        )
      end

      it "returns nil (not Rack Array)" do
        result = strategy.build_access_token
        expect(result).to be_nil
        expect(result).not_to be_a(Array)
      end

      it "sets error key to dingtalk_connection_error" do
        strategy.build_access_token
        expect(strategy.instance_variable_get(:@token_error_key)).to eq(:dingtalk_connection_error)
      end
    end

    context "when DingTalk returns error in response body" do
      let(:mock_response) { double("response", body: '{"errcode":40078,"errmsg":"invalid code"}') }

      before do
        allow(mock_client).to receive(:request).and_return(mock_response)
      end

      it "returns nil" do
        result = strategy.build_access_token
        expect(result).to be_nil
      end

      it "sets error key to dingtalk_token_error" do
        strategy.build_access_token
        expect(strategy.instance_variable_get(:@token_error_key)).to eq(:dingtalk_token_error)
      end
    end

    context "with successful token response" do
      let(:token_response_body) do
        {
          "accessToken" => "at_test_123",
          "refreshToken" => "rt_test_456",
          "expireIn" => 7200,
          "corpId" => "ding_corp_123"
        }.to_json
      end
      let(:mock_response) { double("response", body: token_response_body) }

      before do
        allow(mock_client).to receive(:request).and_return(mock_response)
      end

      it "returns an OAuth2::AccessToken instance" do
        result = strategy.build_access_token
        expect(result).to be_a(::OAuth2::AccessToken)
        expect(result.token).to eq("at_test_123")
      end
    end
  end

  describe "concurrency limiter" do
    it "has MAX_CONCURRENT_REQUESTS constant" do
      expect(OmniAuth::Strategies::Dingtalk::MAX_CONCURRENT_REQUESTS).to eq(5)
    end

    it "tracks concurrent count at class level" do
      expect(OmniAuth::Strategies::Dingtalk.concurrent_count).to eq(0)
    end

    context "when concurrency limit is reached" do
      let(:mock_request) { double("request", params: { "code" => "test_code" }, env: {}) }

      before do
        OmniAuth::Strategies::Dingtalk.concurrent_count = OmniAuth::Strategies::Dingtalk::MAX_CONCURRENT_REQUESTS
        allow(strategy).to receive(:request).and_return(mock_request)
        allow(mock_request).to receive(:ip).and_return("127.0.0.1")
      end

      it "returns nil with service_busy error" do
        result = strategy.build_access_token
        expect(result).to be_nil
        expect(strategy.instance_variable_get(:@token_error_key)).to eq(:dingtalk_service_busy)
      end

      it "does not increment concurrent count" do
        strategy.build_access_token
        expect(OmniAuth::Strategies::Dingtalk.concurrent_count).to eq(OmniAuth::Strategies::Dingtalk::MAX_CONCURRENT_REQUESTS)
      end
    end

    context "when concurrency limit is not reached" do
      let(:mock_request) { double("request", params: { "code" => "test_code" }, env: {}) }
      let(:mock_client) { double("client") }
      let(:mock_connection) { double("connection") }
      let(:mock_options) { double("options") }
      let(:mock_builder) { double("builder", handlers: []) }

      before do
        OmniAuth::Strategies::Dingtalk.concurrent_count = 0
        allow(strategy).to receive(:request).and_return(mock_request)
        allow(mock_request).to receive(:ip).and_return("127.0.0.1")
        allow(strategy).to receive(:client).and_return(mock_client)
        allow(mock_client).to receive(:id).and_return("client_id")
        allow(mock_client).to receive(:secret).and_return("client_secret")
        allow(mock_client).to receive(:connection).and_return(mock_connection)
        allow(mock_connection).to receive(:options).and_return(mock_options)
        allow(mock_connection).to receive(:builder).and_return(mock_builder)
        allow(mock_connection).to receive(:request)
        allow(mock_options).to receive(:timeout=)
        allow(mock_options).to receive(:open_timeout=)
        # Simulate connection failure to test semaphore release
        allow(mock_client).to receive(:request).and_raise(Faraday::ConnectionFailed.new("test"))
      end

      it "releases semaphore after failure" do
        strategy.build_access_token
        expect(OmniAuth::Strategies::Dingtalk.concurrent_count).to eq(0)
      end
    end
  end

  describe "#callback_phase" do
    let(:mock_request) { double("request", params: {}) }
    let(:mock_env) do
      {
        "rack.session" => {},
        "REQUEST_METHOD" => "GET"
      }
    end

    before do
      allow(strategy).to receive(:request).and_return(mock_request)
      allow(strategy).to receive(:env).and_return(mock_env)
      allow(strategy).to receive(:full_host).and_return("https://example.com")
      allow(strategy).to receive(:script_name).and_return("")
      allow(strategy).to receive(:callback_path).and_return("/auth/dingtalk/callback")
      allow(strategy).to receive(:fail!)
      allow(strategy).to receive(:call_app!)
      allow(strategy).to receive(:auth_hash).and_return({})
    end

    context "when build_access_token returns nil" do
      before do
        allow(strategy).to receive(:build_access_token).and_return(nil)
        allow(strategy).to receive(:redirect)
      end

      it "does not crash with expired? on Array" do
        expect { strategy.callback_phase }.not_to raise_error
      end

      it "calls fail! with error key" do
        strategy.callback_phase
        expect(strategy).to have_received(:fail!).with(anything, anything)
      end

      it "redirects to login page" do
        strategy.callback_phase
        expect(strategy).to have_received(:redirect).with("https://example.com/login")
      end
    end

    context "when request params contain error" do
      before do
        allow(mock_request).to receive(:params).and_return({ "error" => "access_denied" })
        allow(strategy).to receive(:redirect)
      end

      it "handles OAuth error and redirects" do
        expect { strategy.callback_phase }.not_to raise_error
        expect(strategy).to have_received(:redirect).with("https://example.com/login")
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

  describe "exponential decreasing timeout" do
    let(:mock_connection) { double("connection") }
    let(:mock_options) { double("options") }
    let(:mock_builder) { double("builder", handlers: []) }

    before do
      allow(mock_connection).to receive(:options).and_return(mock_options)
      allow(mock_connection).to receive(:builder).and_return(mock_builder)
      allow(mock_connection).to receive(:request)
      allow(mock_options).to receive(:timeout=)
      allow(mock_options).to receive(:open_timeout=)
    end

    it "sets initial timeout to 10s and open_timeout to 5s" do
      strategy.send(:configure_connection_with_retry, mock_connection)

      expect(mock_options).to have_received(:timeout=).with(10)
      expect(mock_options).to have_received(:open_timeout=).with(5)
    end

    it "configures retry middleware with max 2 retries" do
      strategy.send(:configure_connection_with_retry, mock_connection)

      expect(mock_connection).to have_received(:request).with(:retry, hash_including(max: 2))
    end

    it "includes retry_block for decreasing timeouts" do
      strategy.send(:configure_connection_with_retry, mock_connection)

      expect(mock_connection).to have_received(:request).with(:retry, hash_including(:retry_block))
    end
  end

  describe "error translation" do
    it "translates known error keys" do
      msg = strategy.send(:translate_error, :dingtalk_service_busy)
      expect(msg).to include("登录人数较多").or include("busy")
    end

    it "falls back for unknown error keys" do
      msg = strategy.send(:translate_error, :some_unknown_error)
      expect(msg).to include("钉钉登录异常").or include("error")
    end
  end
end
