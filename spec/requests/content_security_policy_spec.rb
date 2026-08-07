# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Content-Security-Policy', type: :request do
  it 'incluye un header CSP con script-src restringido a self + nonce' do
    get '/account-verification/abc123'

    csp = response.headers['Content-Security-Policy']
    expect(csp).to be_present
    expect(csp).to match(/script-src 'self' 'nonce-[^']+'/)
    expect(csp).not_to include("script-src 'self' 'unsafe-inline'")
  end

  it 'todo script inline de la página protegida lleva el mismo nonce que el header CSP' do
    sign_in

    get '/home'

    csp   = response.headers['Content-Security-Policy']
    nonce = csp[/nonce-([^']+)/, 1]
    inline_nonces = response.body.scan(/<script[^>]*nonce="([^"]*)"/).flatten

    expect(nonce).to be_present
    expect(inline_nonces).not_to be_empty, 'la página no tiene scripts inline: el test no valida nada'
    expect(inline_nonces).to all(eq(nonce))
  end
end
