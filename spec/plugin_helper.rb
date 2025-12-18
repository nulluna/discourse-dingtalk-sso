# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    add_filter "/vendor/"
  end
end

require "rails_helper"

# Load plugin files
Dir[Rails.root.join("plugins/discourse-dingtalk-sso/lib/**/*.rb")].each { |f| require f }

# Load support files
Dir[Rails.root.join("plugins/discourse-dingtalk-sso/spec/support/**/*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.before(:suite) do
    # Ensure plugin is loaded
    SiteSetting.load_settings(File.join(Rails.root, "plugins", "discourse-dingtalk-sso", "config", "settings.yml"))
  end

  config.before(:each) do
    # Reset SiteSettings before each test
    SiteSetting.dingtalk_enabled = false
    SiteSetting.dingtalk_client_id = ""
    SiteSetting.dingtalk_client_secret = ""
    SiteSetting.dingtalk_scope = "openid"
    SiteSetting.dingtalk_button_title = "with DingTalk"
    SiteSetting.dingtalk_authorize_signup = false
    SiteSetting.dingtalk_overrides_email = false
    SiteSetting.dingtalk_debug_auth = false
  end

  config.after(:each) do
    # Clean up test data
    UserAssociatedAccount.where(provider_name: "dingtalk").destroy_all
    PluginStoreRow.where(plugin_name: "dingtalk_sso").destroy_all
  end
end
