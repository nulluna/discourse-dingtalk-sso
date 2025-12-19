# frozen_string_literal: true

require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class Dingtalk < OmniAuth::Strategies::OAuth2
      option :name, "dingtalk"

      option :client_options,
        site: "https://api.dingtalk.com",
        authorize_url: "https://login.dingtalk.com/oauth2/auth",
        token_url: "https://api.dingtalk.com/v1.0/oauth2/userAccessToken"

      option :authorize_params,
        prompt: "consent"

      option :token_params,
        grant_type: "authorization_code"

      # Override token request to use DingTalk's specific JSON format
      # DingTalk requires POST with JSON body: clientId, clientSecret, code, grantType
      def build_access_token
        verifier = request.params["code"]
        return nil if verifier.blank?

        response = nil
        params = {
          clientId: client.id,
          clientSecret: client.secret,
          code: verifier,
          grantType: "authorization_code"
        }

        response = client.request(:post, token_url, {
          body: params.to_json,
          headers: {
            "Content-Type" => "application/json",
            "Accept" => "application/json"
          }
        })

        token_data = JSON.parse(response.body)

        # Check for errors in response
        if token_data["errcode"] && token_data["errcode"] != 0
          error_msg = "DingTalk token error: #{token_data['errmsg']} (code: #{token_data['errcode']})"
          log_error(error_msg)
          raise ::OAuth2::Error.new(response)
        end

        # Build OAuth2 access token from DingTalk response
        ::OAuth2::AccessToken.from_hash(client, {
          access_token: token_data["accessToken"],
          refresh_token: token_data["refreshToken"],
          expires_in: token_data["expireIn"],
          corp_id: token_data["corpId"]
        }.merge(token_data))

      rescue ::OAuth2::Error => e
        log_error("DingTalk OAuth token error: #{e.message}")
        raise e
      rescue JSON::ParserError => e
        log_error("DingTalk token response parse error: #{e.message}")
        raise ::OAuth2::Error.new(response || nil)
      rescue StandardError => e
        log_error("DingTalk token request failed: #{e.class} - #{e.message}")
        raise ::OAuth2::Error.new(response || nil)
      end

      def token_url
        # Use absolute URL for token request
        url = options[:client_options][:token_url]
        return url if url&.start_with?("http")

        # Fallback to relative path if absolute URL not provided
        "/v1.0/oauth2/userAccessToken"
      end

      # Override request method to handle DingTalk's JSON body format
      def request_phase
        options[:authorize_params].merge!(options_for("authorize"))
        if OmniAuth.config.test_mode
          @env ||= {}
          @env["rack.session"] ||= {}
        end
        redirect client.auth_code.authorize_url(
          { redirect_uri: callback_url }.merge(authorize_params)
        )
      end

      uid { raw_info["unionId"] || raw_info["openId"] }

      info do
        {
          name: raw_info["nick"] || raw_info["name"],
          email: raw_info["email"],
          phone: raw_info["mobile"],
          nickname: raw_info["nick"] || raw_info["name"]
        }
      end

      extra do
        {
          raw_info: raw_info,
          corp_id: access_token.params["corpId"] || access_token.params["corp_id"]
        }
      end

      def raw_info
        @raw_info ||= begin
          return {} if access_token&.token.blank?

          response = access_token.get(
            "/v1.0/contact/users/me",
            headers: {
              "x-acs-dingtalk-access-token" => access_token.token,
              "Content-Type" => "application/json"
            }
          )

          data = JSON.parse(response.body)

          # Check for DingTalk API errors
          if data["errcode"] && data["errcode"] != 0
            log_error("DingTalk API error: #{data['errmsg']} (code: #{data['errcode']})")
            return {}
          end

          # Debug: Log actual API response fields
          if defined?(Rails) && Rails.logger
            Rails.logger.info "DingTalk API返回字段: #{data.keys.inspect}"
            Rails.logger.info "DingTalk API完整响应: #{data.inspect}"
          end

          data
        rescue ::OAuth2::Error => e
          log_error("DingTalk user info OAuth error: #{e.message}")
          {}
        rescue JSON::ParserError => e
          log_error("DingTalk user info parse error: #{e.message}")
          {}
        rescue StandardError => e
          log_error("DingTalk user info fetch failed: #{e.class} - #{e.message}")
          {}
        end
      end

      def callback_url
        options[:redirect_uri] || (full_host + script_name + callback_path)
      end

      protected

      def deep_symbolize(options)
        hash = {}
        options.each do |key, value|
          hash[key.to_sym] = value.is_a?(Hash) ? deep_symbolize(value) : value
        end
        hash
      end

      def log_error(message)
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.error(message)
        else
          puts "[DingTalk OAuth Error] #{message}"
        end
      end
    end
  end
end

OmniAuth.config.add_camelization "dingtalk", "Dingtalk"
