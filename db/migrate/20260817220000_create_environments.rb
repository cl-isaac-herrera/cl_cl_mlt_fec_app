# frozen_string_literal: true

# Catálogo de ambientes de Hacienda. Es la contraparte de `dbo.Environment` del
# API .NET, con la nomenclatura de este proyecto.
#
# Agrupa lo que NO varía por compañía sino por ambiente de emisión: los tres
# endpoints de Hacienda y el número de resolución. En el .NET, `companies` apunta
# a esta tabla por `EnvironmentId` y el mismo ambiente lo comparten todas las
# compañías que emiten contra él.
#
# `is_prod` es lo que distingue pruebas de producción, y es el dato del que
# dependen valores que hoy viven repetidos en cada compañía: el comentario del
# legacy sobre `client_id` dice literalmente `pruebas "api-stag", produccion
# "api-prod"` (`CLVS_FE.Models/Configuracion/Company.cs:50`). Esos dos campos se
# dejaron en `companies` por decisión de producto; si algún día se normalizan,
# este es su lugar.
#
# Las tres URIs sí están vivas: `uri_token` obtiene el bearer, `uri_send` envía el
# documento y `uri_check` consulta su estado (`CLVS_FE.Hacienda/
# TransaccionesHacienda.cs`), y se validan como no vacías antes de emitir.
# `resolution_number` y `resolution_date` no tienen consumidor en el C# del
# legacy — se migran igual porque el número de resolución es un dato que suele
# imprimirse en la factura y el consumidor podría ser el `.rpt` de Crystal, que
# no se puede inspeccionar con grep.
#
# `resolution_date` era `c.String()` en el legacy. Acá es `date`: si el valor se
# imprime literal en el PDF, hay que formatearlo al mostrarlo (`CLAUDE.md` §5),
# no guardarlo como texto.
class CreateEnvironments < ActiveRecord::Migration[8.1]
  def change
    create_table :environments do |t|
      t.boolean :is_prod, null: false, default: false

      t.string :uri_token
      t.string :uri_send
      t.string :uri_check

      t.string :resolution_number
      t.date   :resolution_date

      # Columnas de auditoría y baja lógica, como el resto de las tablas del
      # proyecto (`Auditable` + `SoftDeletable`).
      t.boolean :is_active, null: false, default: true
      t.string  :created_by
      t.string  :updated_by
      t.timestamps
    end
  end
end
