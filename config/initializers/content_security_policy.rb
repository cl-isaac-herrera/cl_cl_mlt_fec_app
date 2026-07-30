# frozen_string_literal: true

# Content-Security-Policy — ver AUDITORIA_PLATFORM_STANDARDS.md, hallazgo HIGH "CSP activo".
#
# script-src va sin 'unsafe-inline': todo <script> inline (incluido el auth-gate
# síncrono de protected.html.erb) recibe un nonce por request vía
# content_security_policy_nonce_generator. javascript_importmap_tags ya inyecta
# ese nonce automáticamente (importmap-rails); el <script> del auth-gate se generó
# con javascript_tag(nonce: true) para recibir el mismo tratamiento.
#
# style-src SÍ necesita 'unsafe-inline': la app usa style="..." inline en cientos
# de badges/tooltips generados desde JS (ver CLAUDE.md §1 y §25 del proyecto) — un
# nonce no cubre atributos style="" (solo bloques <style>), así que sin
# 'unsafe-inline' se rompería la UI completa. Es una relajación deliberada, no un
# descuido: script-src (el vector real de XSS) queda estricto.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline, 'https://fonts.googleapis.com'
    policy.font_src     :self, 'https://fonts.gstatic.com'
    policy.img_src      :self, :data
    policy.connect_src  :self
    policy.object_src   :none
    policy.base_uri     :self
    policy.form_action  :self
    policy.frame_ancestors :self
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  config.content_security_policy_report_only = false
end
