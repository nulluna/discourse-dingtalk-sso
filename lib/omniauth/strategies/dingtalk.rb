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
      # DingTalk requires clientId/clientSecret instead of client_id/client_secret
      def build_access_token
        verifier = request.params["code"]
        client.auth_code.get_token(
          verifier,
          {
            redirect_uri: callback_url,
            client_id: client.id,
            client_secret: client.secret
          }.merge(token_params.to_hash(symbolize_keys: true)),
          deep_symbolize(options.auth_token_params)
        )
      rescue ::OAuth2::Error => e
        Rails.logger.error "DingTalk OAuth token error: #{e.message}"
        raise e
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

      uid { raw_info["unionId"] }

      info do
        {
          name: raw_info["nick"],
          email: raw_info["email"],
          phone: raw_info["mobile"],
          nickname: raw_info["nick"]
        }
      end

      extra do
        {
          raw_info: raw_info,
          corp_id: access_token.params["corpId"]
        }
      end

      def raw_info
        @raw_info ||= begin
          response = access_token.get(
            "/v1.0/contact/users/me",
            headers: {
              "x-acs-dingtalk-access-token" => access_token.token,
              "Content-Type" => "application/json"
            }
          )
          JSON.parse(response.body)
        rescue ::OAuth2::Error, JSON::ParserError => e
          Rails.logger.error "DingTalk user info fetch error: #{e.message}"
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
    end
  end
end

OmniAuth.config.add_camelization "dingtalk", "Dingtalk"
