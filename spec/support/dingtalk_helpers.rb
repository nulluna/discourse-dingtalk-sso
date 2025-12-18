# frozen_string_literal: true

module DingtalkHelpers
  def mock_dingtalk_auth(overrides = {})
    default_auth = {
      provider: "dingtalk",
      uid: "union_test_#{SecureRandom.hex(8)}",
      info: {
        name: "Test User",
        email: "test@example.com",
        nickname: "testuser",
        phone: "13800138000"
      },
      extra: {
        raw_info: {
          "unionId" => "union_test_#{SecureRandom.hex(8)}",
          "openId" => "open_test_#{SecureRandom.hex(8)}",
          "nick" => "Test User",
          "email" => "test@example.com",
          "mobile" => "13800138000"
        },
        corp_id: "ding_test_corp"
      }
    }

    deep_merge(default_auth, overrides)
  end

  def mock_dingtalk_token_response(success: true)
    if success
      {
        accessToken: "mock_access_token_#{SecureRandom.hex(16)}",
        refreshToken: "mock_refresh_token_#{SecureRandom.hex(16)}",
        expireIn: 7200,
        corpId: "ding_test_corp"
      }.to_json
    else
      {
        errcode: 40014,
        errmsg: "invalid access token"
      }.to_json
    end
  end

  def mock_dingtalk_user_info(success: true)
    if success
      {
        nick: "Test User",
        unionId: "union_test_123",
        openId: "open_test_456",
        email: "test@example.com",
        mobile: "13800138000"
      }.to_json
    else
      {
        errcode: 40031,
        errmsg: "access token expired"
      }.to_json
    end
  end

  private

  def deep_merge(hash1, hash2)
    hash1.merge(hash2) do |_key, oldval, newval|
      if oldval.is_a?(Hash) && newval.is_a?(Hash)
        deep_merge(oldval, newval)
      else
        newval
      end
    end
  end
end

RSpec.configure do |config|
  config.include DingtalkHelpers, type: :request
  config.include DingtalkHelpers, type: :model
end
