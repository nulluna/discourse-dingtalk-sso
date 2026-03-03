# frozen_string_literal: true

require "omniauth-oauth2"
require "securerandom"

module OmniAuth
  module Strategies
    class Dingtalk < OmniAuth::Strategies::OAuth2
      # 并发限制：最多同时 5 个请求访问钉钉 API，防止 TCP 连接雪崩
      MAX_CONCURRENT_REQUESTS = 5
      SEMAPHORE = Mutex.new
      @concurrent_count = 0

      class << self
        attr_accessor :concurrent_count
      end

      option :name, "dingtalk"

      option :client_options,
        site: "https://api.dingtalk.com",
        authorize_url: "https://login.dingtalk.com/oauth2/auth",
        token_url: "https://api.dingtalk.com/v1.0/oauth2/userAccessToken"

      option :authorize_params,
        prompt: "consent"

      option :token_params,
        grant_type: "authorization_code"

      # Override callback_phase to prevent `expired?` on Array crash
      # When build_access_token fails, it returns nil instead of a Rack Array,
      # so we intercept and redirect to login with a friendly error message.
      def callback_phase
        error = request.params["error_reason"] || request.params["error"]
        if error
          fail!(error, CallbackError.new(request.params["error"], request.params["error_description"], request.params["error_uri"]))
          return redirect_to_login_with_error(:dingtalk_token_error)
        end

        # Reset error state
        @token_error_key = nil
        @token_error_exception = nil

        token = build_access_token

        # build_access_token returns nil on failure (instead of Rack Array from fail!)
        unless token.is_a?(::OAuth2::AccessToken)
          error_key = @token_error_key || :dingtalk_unknown_error
          log_with_context("callback_phase", "token acquisition failed, error_key=#{error_key}, exception=#{@token_error_exception&.class}")
          fail!(error_key, @token_error_exception)
          return redirect_to_login_with_error(error_key)
        end

        self.access_token = token

        # Skip OAuth2#callback_phase (which would call build_access_token again
        # and trigger expired? on the result). Call grandparent directly.
        env["omniauth.auth"] = auth_hash
        call_app!
      rescue ::OAuth2::Error, CallbackError => e
        log_with_context("callback_phase", "OAuth2 error: #{e.class} - #{e.message}")
        fail!(:dingtalk_token_error, e)
        redirect_to_login_with_error(:dingtalk_token_error)
      rescue Timeout::Error, Faraday::TimeoutError => e
        log_with_context("callback_phase", "Timeout: #{e.class} - #{e.message}")
        fail!(:dingtalk_timeout_error, e)
        redirect_to_login_with_error(:dingtalk_timeout_error)
      rescue Faraday::ConnectionFailed => e
        log_with_context("callback_phase", "Connection failed: #{e.class} - #{e.message}")
        fail!(:dingtalk_connection_error, e)
        redirect_to_login_with_error(:dingtalk_connection_error)
      rescue StandardError => e
        log_with_context("callback_phase", "Unexpected: #{e.class} - #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
        fail!(:dingtalk_unknown_error, e)
        redirect_to_login_with_error(:dingtalk_unknown_error)
      end

      # Override token request to use DingTalk's specific JSON format
      # DingTalk requires POST with JSON body: clientId, clientSecret, code, grantType
      # Returns OAuth2::AccessToken on success, nil on failure (never returns Rack Array)
      def build_access_token
        verifier = request.params["code"]
        if verifier.blank?
          log_with_context("build_access_token", "missing authorization code")
          @token_error_key = :dingtalk_token_error
          return nil
        end

        # 并发限制检查
        unless acquire_semaphore
          log_with_context("build_access_token", "concurrency limit reached (#{MAX_CONCURRENT_REQUESTS}), rejecting request")
          @token_error_key = :dingtalk_service_busy
          return nil
        end

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = nil
        params = {
          clientId: client.id,
          clientSecret: client.secret,
          code: verifier,
          grantType: "authorization_code"
        }

        # Configure timeout and retry with exponential decreasing timeouts
        configure_connection_with_retry(client.connection)

        response = client.request(:post, token_url, {
          body: params.to_json,
          headers: {
            "Content-Type" => "application/json",
            "Accept" => "application/json"
          }
        })

        elapsed = elapsed_ms(start_time)
        token_data = JSON.parse(response.body)

        # Check for errors in response
        if token_data["errcode"] && token_data["errcode"] != 0
          error_msg = "errcode=#{token_data['errcode']}, errmsg=#{token_data['errmsg']}"
          log_with_context("build_access_token", "API error response: #{error_msg}, elapsed=#{elapsed}ms")
          @token_error_key = :dingtalk_token_error
          @token_error_exception = StandardError.new("DingTalk token error: #{error_msg}")
          return nil
        end

        log_with_context("build_access_token", "token acquired successfully, elapsed=#{elapsed}ms", level: :info)

        # Build OAuth2 access token from DingTalk response
        ::OAuth2::AccessToken.from_hash(client, {
          access_token: token_data["accessToken"],
          refresh_token: token_data["refreshToken"],
          expires_in: token_data["expireIn"],
          corp_id: token_data["corpId"]
        }.merge(token_data))

      rescue ::OAuth2::Error => e
        log_with_context("build_access_token", "OAuth2 error: #{e.message}, elapsed=#{elapsed_ms(start_time)}ms")
        @token_error_key = :dingtalk_token_error
        @token_error_exception = e
        nil
      rescue Timeout::Error, Faraday::TimeoutError => e
        log_with_context("build_access_token", "Timeout: #{e.class} - #{e.message}, elapsed=#{elapsed_ms(start_time)}ms")
        @token_error_key = :dingtalk_timeout_error
        @token_error_exception = e
        nil
      rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED => e
        log_with_context("build_access_token", "Connection failed: #{e.class} - #{e.message}, elapsed=#{elapsed_ms(start_time)}ms")
        @token_error_key = :dingtalk_connection_error
        @token_error_exception = e
        nil
      rescue JSON::ParserError => e
        log_with_context("build_access_token", "JSON parse error: #{e.message}, body=#{response&.body&.truncate(200)}, elapsed=#{elapsed_ms(start_time)}ms")
        @token_error_key = :dingtalk_parse_error
        @token_error_exception = e
        nil
      rescue StandardError => e
        log_with_context("build_access_token", "Unexpected: #{e.class} - #{e.message}, elapsed=#{elapsed_ms(start_time)}ms\n#{e.backtrace&.first(5)&.join("\n")}")
        @token_error_key = :dingtalk_unknown_error
        @token_error_exception = e
        nil
      ensure
        release_semaphore if @semaphore_acquired
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
          corp_id: access_token&.params&.dig("corpId") || access_token&.params&.dig("corp_id")
        }
      end

      def raw_info
        @raw_info ||= begin
          return {} if access_token&.token.blank?

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # Configure timeout and retry for user info request (if client connection is available)
          if access_token.respond_to?(:client) && access_token.client.respond_to?(:connection)
            configure_connection_with_retry(access_token.client.connection)
          end

          response = access_token.get(
            "/v1.0/contact/users/me",
            headers: {
              "x-acs-dingtalk-access-token" => access_token.token,
              "Content-Type" => "application/json"
            }
          )

          elapsed = elapsed_ms(start_time)
          data = JSON.parse(response.body)

          # Check for DingTalk API errors
          if data["errcode"] && data["errcode"] != 0
            log_with_context("raw_info", "API error: errcode=#{data['errcode']}, errmsg=#{data['errmsg']}, elapsed=#{elapsed}ms")
            return {}
          end

          log_with_context("raw_info", "user info fetched, fields=#{data.keys.inspect}, elapsed=#{elapsed}ms", level: :info)
          data
        rescue ::OAuth2::Error => e
          log_with_context("raw_info", "OAuth2 error: #{e.message}, elapsed=#{elapsed_ms(start_time)}ms")
          {}
        rescue Timeout::Error, Faraday::TimeoutError => e
          log_with_context("raw_info", "Timeout: #{e.class} - #{e.message}, elapsed=#{elapsed_ms(start_time)}ms")
          {}
        rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED => e
          log_with_context("raw_info", "Connection failed: #{e.class} - #{e.message}, elapsed=#{elapsed_ms(start_time)}ms")
          {}
        rescue JSON::ParserError => e
          log_with_context("raw_info", "JSON parse error: #{e.message}, body=#{response&.body&.truncate(200)}, elapsed=#{elapsed_ms(start_time)}ms")
          {}
        rescue StandardError => e
          log_with_context("raw_info", "Unexpected: #{e.class} - #{e.message}, elapsed=#{elapsed_ms(start_time)}ms")
          {}
        end
      end

      def callback_url
        options[:redirect_uri] || (full_host + script_name + callback_path)
      end

      protected

      # Configure connection with exponential decreasing timeout and retry
      # Retry 2 times (3 attempts total) with decreasing timeouts: 10s → 6s → 4s
      # This prevents long waits on retries when DingTalk API is slow/overloaded
      # @param connection [Faraday::Connection] The Faraday connection object
      def configure_connection_with_retry(connection)
        # Initial timeout (first attempt uses these values)
        connection.options.timeout = 10      # Total timeout: 10 seconds
        connection.options.open_timeout = 5  # Connection timeout: 5 seconds

        # Configure retry middleware if not already configured
        unless connection.builder.handlers.include?(Faraday::Retry::Middleware)
          attempt_count = 0
          connection.request :retry, {
            max: 2,                                    # Retry up to 2 times (3 attempts total)
            interval: 0.5,                             # Initial retry interval: 0.5 seconds
            backoff_factor: 2,                         # Exponential backoff: 0.5s, 1s
            exceptions: [                              # Retry only on network errors
              Faraday::TimeoutError,
              Faraday::ConnectionFailed,
              Errno::ETIMEDOUT,
              Errno::ECONNREFUSED,
              Errno::ECONNRESET
            ],
            methods: %i[get post],                     # Retry GET and POST requests
            retry_statuses: [429, 500, 502, 503, 504], # Retry on server errors and rate limiting
            retry_block: ->(env, _opts, retries_remaining, exception) {
              attempt_count += 1
              # Exponential decreasing timeout: attempt 1→6s/3s, attempt 2→4s/2s
              case attempt_count
              when 1
                env.request.timeout = 6
                env.request.open_timeout = 3
              else
                env.request.timeout = 4
                env.request.open_timeout = 2
              end
              log_retry(attempt_count, retries_remaining, exception)
            }
          }
        end
      end

      private

      # 并发信号量：获取
      def acquire_semaphore
        @semaphore_acquired = false
        SEMAPHORE.synchronize do
          if self.class.concurrent_count >= MAX_CONCURRENT_REQUESTS
            return false
          end
          self.class.concurrent_count += 1
          @semaphore_acquired = true
        end
        true
      end

      # 并发信号量：释放
      def release_semaphore
        SEMAPHORE.synchronize do
          self.class.concurrent_count -= 1 if self.class.concurrent_count > 0
        end
        @semaphore_acquired = false
      end

      # 请求唯一标识（用于日志追踪）
      def request_id
        @request_id ||= begin
          env_request_id = request.env["action_dispatch.request_id"] rescue nil
          env_request_id || SecureRandom.hex(4)
        end
      end

      # 请求来源 IP
      def request_ip
        request.ip rescue "unknown"
      end

      # 结构化日志：带上下文（默认 error 级别）
      def log_with_context(method, message, level: :error)
        concurrent = self.class.concurrent_count rescue "?"
        full_message = "[DingTalk OAuth] [#{request_id}] [#{method}] ip=#{request_ip} concurrent=#{concurrent} #{message}"
        if defined?(Rails) && Rails.respond_to?(:logger)
          case level
          when :info
            Rails.logger.info(full_message)
          when :warn
            Rails.logger.warn(full_message)
          else
            Rails.logger.error(full_message)
          end
        else
          puts full_message
        end
      end

      # 重试日志
      def log_retry(attempt, retries_remaining, exception)
        log_with_context("retry", "attempt=##{attempt + 1}, remaining=#{retries_remaining}, error=#{exception&.class}: #{exception&.message}")
      end

      # 计算耗时（毫秒）
      def elapsed_ms(start_time)
        return 0 unless start_time
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
      end

      # Redirect to login page with a user-friendly error message
      # Uses Discourse's standard flash mechanism via session
      def redirect_to_login_with_error(error_key)
        error_message = translate_error(error_key)

        # Store error in session for Discourse to display on login page
        session = env["rack.session"] || {}
        session[:flash] = { error: error_message } if session.respond_to?(:[]=)

        # Redirect to login page with error parameter
        login_url = "#{full_host}/login"
        redirect login_url
      end

      # Map error key to localized user-facing message
      def translate_error(error_key)
        messages = {
          dingtalk_token_error: "钉钉授权失败，请重新登录 / DingTalk authorization failed, please login again",
          dingtalk_timeout_error: "钉钉服务器响应超时，请检查网络后重试 / DingTalk server timed out, please retry",
          dingtalk_connection_error: "无法连接到钉钉服务器，请稍后重试 / Cannot connect to DingTalk server, please retry later",
          dingtalk_parse_error: "钉钉响应格式错误，请联系管理员 / DingTalk response error, contact admin",
          dingtalk_unknown_error: "钉钉登录异常，请稍后重试 / DingTalk login error, please retry later",
          dingtalk_service_busy: "当前登录人数较多，请稍候几秒后重试 / Server is busy, please retry in a few seconds",
          dingtalk_rate_limited: "请求过于频繁，请稍后重试 / Too many requests, please try again later"
        }

        # Try I18n first, fallback to hardcoded
        if defined?(I18n)
          I18n.t("login.dingtalk.#{error_key}", default: messages[error_key] || messages[:dingtalk_unknown_error])
        else
          messages[error_key] || messages[:dingtalk_unknown_error]
        end
      end

      # Legacy log_error kept for compatibility
      def log_error(message)
        log_with_context("error", message)
      end
    end
  end
end

OmniAuth.config.add_camelization "dingtalk", "Dingtalk"
