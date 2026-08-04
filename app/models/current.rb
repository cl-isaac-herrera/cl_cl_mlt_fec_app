# frozen_string_literal: true

# Contexto de request thread-local. Se limpia automáticamente al final de cada request.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :token, :company_id, :request_id
end
