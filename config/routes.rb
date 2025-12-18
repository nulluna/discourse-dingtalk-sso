# frozen_string_literal: true

# DingTalk SSO plugin uses OmniAuth routes which are automatically registered
# No custom routes needed for OAuth authentication flow
#
# OmniAuth automatically provides:
# - GET  /auth/dingtalk          - redirect to DingTalk OAuth
# - GET  /auth/dingtalk/callback - handle OAuth callback
# - POST /auth/dingtalk/callback - handle OAuth callback (alternate)

# DiscourseDingtalk::Engine.routes.draw do
#   # Custom routes can be added here if needed
# end
#
# Discourse::Application.routes.draw do
#   # mount ::DiscourseDingtalk::Engine, at: "/dingtalk" if needed
# end
