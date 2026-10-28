Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "ready", to: "readiness#show", as: :readiness
  get "health/operations", to: "operational_health#show"
  get "robots.txt", to: "seo#robots", defaults: { format: :text }
  get "sitemap.xml", to: "seo#sitemap", defaults: { format: :xml }
  post "webhooks/mollie", to: "webhooks/mollie#create"

  scope "(:locale)", locale: /nl|fr|de|en/ do
    root "home#index"

    get "pricing", to: "pages#pricing", as: :pricing
    get "privacy", to: "pages#privacy", as: :privacy
    get "terms", to: "pages#terms", as: :terms
    get "cookies", to: "pages#cookie_policy", as: :cookies
    get "legal-notice", to: "pages#legal_notice", as: :legal_notice

    resource :session, only: %i[new create destroy]
    resources :passwords, param: :token, only: %i[new create edit update]
    resource :registration, only: %i[new create]
    get "email-verification/:token", to: "email_verifications#show", as: :email_verification
    post "email-verification/:token", to: "email_verifications#confirm", as: :confirm_email_verification
    get "directory-verification/:token", to: "directory_verifications#show", as: :directory_verification
    post "directory-verification/:token", to: "directory_verifications#confirm", as: :confirm_directory_verification
    resource :verification_status, only: %i[show create], controller: "verification_status" do
      post :retry_directory
    end
    resource :settings, only: %i[show update]
    get "settings/email", to: "email_changes#new", as: :email_change
    post "settings/email", to: "email_changes#create"
    resources :privacy_requests, only: %i[index new create]

    get "billing", to: "billing#show", as: :billing
    post "billing/checkout", to: "billing#checkout", as: :billing_checkout
    post "billing/cancel", to: "billing#cancel", as: :billing_cancel
    get "billing/return", to: "billing#return", as: :billing_return

    get "dashboard", to: "dashboard#index", as: :dashboard
    resources :notifications, only: %i[show update] do
      collection do
        patch :mark_all
      end
    end
    namespace :admin do
      root "users#index"
      get "login", to: "sessions#new", as: :login
      post "login", to: "sessions#create"
      resources :users, only: %i[index show update] do
        member do
          patch :suspend
          patch :restore
          patch :revoke_sessions, path: "revoke-sessions"
        end
      end
      get "mfa/setup", to: "mfa#setup", as: :mfa_setup
      post "mfa/setup", to: "mfa#confirm_setup"
      get "mfa/challenge", to: "mfa#challenge", as: :mfa_challenge
      post "mfa/challenge", to: "mfa#verify"
      resources :verifications, only: %i[index update]
      resources :founding_accesses, param: :firm_id, only: %i[index create destroy]
      resources :reports, only: %i[index update]
      resources :privacy_requests, only: %i[index update]
    end

    resources :assignments, only: %i[index show new create] do
      resources :reports, only: %i[new create]
      member do
        patch :cancel
        patch :complete
      end

      resources :proposals, only: :create do
        member do
          patch :accept
          patch :decline
          patch :withdraw
        end
      end
    end
  end
end
