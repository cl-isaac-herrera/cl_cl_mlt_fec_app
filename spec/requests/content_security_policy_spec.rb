# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Content-Security-Policy', type: :request do
  it 'incluye un header CSP con script-src restringido a self + nonce' do
    get '/login'

    csp = response.headers['Content-Security-Policy']
    expect(csp).to be_present
    expect(csp).to match(/script-src 'self' 'nonce-[^']+'/)
    expect(csp).not_to include("script-src 'self' 'unsafe-inline'")
  end

  it 'el script inline del auth-gate lleva el mismo nonce que el header CSP' do
    get '/home'

    csp = response.headers['Content-Security-Policy']
    nonce = csp[/nonce-([^']+)/, 1]

    expect(nonce).to be_present
    expect(response.body.scan(/<script[^>]*nonce="([^"]*)"/).flatten).to all(eq(nonce))
  end
end
