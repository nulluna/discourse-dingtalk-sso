# frozen_string_literal: true

# name: discourse-dingtalk-sso
# about: 钉钉企业内部应用SSO登录集成 / DingTalk Enterprise SSO Integration
# meta_topic_id: TODO
# version: 1.0.0
# authors: Discourse Community
# url: https://github.com/discourse/discourse-dingtalk-sso
# required_version: 2.7.0

enabled_site_setting :dingtalk_enabled

module ::DiscourseDingtalk
  PLUGIN_NAME = "discourse-dingtalk-sso"
end

require_relative "lib/discourse_dingtalk/engine"
require_relative "lib/omniauth/strategies/dingtalk"
require_relative "lib/dingtalk_authenticator"

auth_provider(
  title_setting: "dingtalk_button_title",
  authenticator: DingtalkAuthenticator.new,
  enabled_setting: "dingtalk_enabled",
  icon: "fab-dingtalk"
)

after_initialize do
  # Load plugin models
  require_relative "models/dingtalk_user_organization"

  # Plugin initialization logic
end
