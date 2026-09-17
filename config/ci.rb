# Run using bin/ci
#
# Adaptado del default de Rails 8: este proyecto usa RSpec (ver .rspec,
# spec/rails_helper.rb), no Minitest, así que "Tests" corre `bundle exec rspec`
# y no `bin/rails test`. Tampoco corre `bin/setup` en el paso de Setup — ese
# script es el bootstrap interactivo de un producto nuevo (pide nombre,
# tipo, SAP sí/no por stdin), no un quickstart de CI; el equivalente en CI es
# preparar las bases ya migradas.

CI.run do
  # ⚠️ NO correr `db:seed` acá. La suite asume una base de test SIN sembrar —
  # cada spec arma sus propios datos con factories — y sembrar de verdad
  # inserta filas permanentes (fuera de la transacción de cada test) que
  # CHOCAN con las que los specs intentan crear (`ActiveRecord::RecordInvalid:
  # El código ya está en uso`). Confirmado en vivo 2026-09-16: sembrar la base
  # de test rompió 188 specs que antes pasaban.
  # `db:prepare` alcanza para crear/migrar primary+cache+queue; solo siembra
  # solo si la base se acaba de crear por primera vez (Rails,
  # `Tasks::DatabaseTasks.prepare_all`), así que en CI (base siempre nueva)
  # hay que forzar el schema en vez de prepare para no heredar ese sembrado.
  step "Setup", "bin/rails db:create db:schema:load"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: RSpec", "bundle exec rspec"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
