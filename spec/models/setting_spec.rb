require 'rails_helper'

RSpec.describe Setting, type: :model do
  it 'es válido con los atributos del factory' do
    expect(build(:setting)).to be_valid
  end

  describe 'convención del code' do
    it 'acepta SCREAMING_SNAKE con varios tramos' do
      expect(build(:setting, code: 'DOCS_DB_ODBC_QUERY_TIMEOUT')).to be_valid
    end

    # Es lo que impide que una importación desde el .NET inserte los `code` del
    # origen sin traducir (ver `db/setting_code_map.yml`).
    it 'rechaza el PascalCase del .NET' do
      setting = build(:setting, code: 'CedulaProveedorSistemas')

      expect(setting).not_to be_valid
      expect(setting.errors[:code]).to be_present
    end

    it 'rechaza un code sin separador' do
      expect(build(:setting, code: 'DOCS')).not_to be_valid
    end

    it 'rechaza minúsculas' do
      expect(build(:setting, code: 'docs_db_user')).not_to be_valid
    end

    # §30: sin la clave en `config/locales/es.yml`, el mensaje que llega al
    # usuario es el bloque "Translation missing…".
    it 'traduce el mensaje del formato' do
      setting = build(:setting, code: 'MalFormado')
      setting.valid?

      expect(setting.errors.full_messages.first)
        .to eq('El código debe seguir la convención {DOMINIO}_{CAMPO} en mayúsculas, ' \
               'con guiones bajos como separador (por ejemplo DOCS_DB_ODBC_USER)')
    end
  end

  describe 'unicidad del code' do
    it 'rechaza un duplicado' do
      create(:setting, code: 'DOCS_DB_USER')

      expect(build(:setting, code: 'DOCS_DB_USER')).not_to be_valid
    end

    # `SoftDeletable` instala `default_scope { where(is_active: true) }`, y el
    # índice único de la base NO excluye a las inactivas: sin el
    # `unscope(where: :is_active)` de la validación, esto pasaría de largo y el
    # choque saldría como un 500 (CLAUDE.md §28).
    it 'también rechaza el duplicado de una fila dada de baja' do
      create(:setting, code: 'DOCS_DB_USER').soft_delete!

      duplicate = build(:setting, code: 'DOCS_DB_USER')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:code]).to be_present
    end
  end

  describe 'cifrado del valor' do
    it 'no deja el valor en claro en la base' do
      create(:setting, code: 'DOCS_DB_PASSWORD', value: 'sup3r-s3cr3t')

      raw = described_class.connection.select_value(
        "SELECT value FROM settings WHERE code = 'DOCS_DB_PASSWORD'"
      )

      expect(raw).to be_present
      expect(raw).not_to include('sup3r-s3cr3t')
      # El sobre de ActiveRecord Encryption es un JSON con el criptograma y el IV.
      expect(raw).to include('"p"')
    end

    it 'lo devuelve descifrado desde el modelo' do
      setting = create(:setting, value: 'sup3r-s3cr3t')

      expect(setting.reload.value).to eq('sup3r-s3cr3t')
    end

    # El cifrado es no determinista: el mismo texto produce un criptograma
    # distinto cada vez, así que no se puede buscar por esta columna.
    it 'no se puede consultar por valor' do
      create(:setting, value: 'buscame')

      expect(described_class.where(value: 'buscame')).to be_empty
    end
  end

  describe 'is_visible' do
    it 'devuelve el valor cuando es visible' do
      setting = create(:setting, :configured, is_visible: true)

      expect(setting.visible_value).to eq('un-valor')
    end

    # El arreglo de la fuga del .NET: `CrystalPassword` viajaba en claro al
    # browser y la UI la enmascaraba con un `type="password"` con botón para
    # revelarla.
    it 'tapa el valor cuando está oculto, pero informa que existe' do
      setting = create(:setting, :hidden)

      expect(setting.visible_value).to be_nil
      expect(setting.value?).to be(true)
    end
  end

  describe '.value_for' do
    it 'devuelve el valor del code' do
      create(:setting, code: 'DOCS_DB_SERVER', value: 'CLSQL01')

      expect(described_class.value_for('DOCS_DB_SERVER')).to eq('CLSQL01')
    end

    it 'devuelve nil cuando el ajuste no existe' do
      expect(described_class.value_for('NO_EXISTE_CODE')).to be_nil
    end

    it 'devuelve nil cuando está sembrado sin valor' do
      create(:setting, code: 'DOCS_DB_SERVER', value: nil)

      expect(described_class.value_for('DOCS_DB_SERVER')).to be_nil
    end

    it 'ignora un ajuste dado de baja' do
      create(:setting, code: 'DOCS_DB_SERVER', value: 'CLSQL01').soft_delete!

      expect(described_class.value_for('DOCS_DB_SERVER')).to be_nil
    end
  end

  describe '.group' do
    before do
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_SERVER', value: 'CLSQL01')
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_USER',   value: 'fec_ro')
      create(:setting, group_code: 'OTRO_GRUPO',   code: 'OTRO_GRUPO_SERVER',   value: 'no-va')
    end

    it 'devuelve los valores del grupo con el prefijo recortado' do
      expect(described_class.group('DOCS_DB_ODBC'))
        .to eq('SERVER' => 'CLSQL01', 'USER' => 'fec_ro')
    end

    # Recorta por el largo del `group_code` y no partiendo por `_`: si partiera,
    # el campo quedaría en 'TIMEOUT' en vez de 'QUERY_TIMEOUT'.
    it 'conserva un campo de dos palabras' do
      create(:setting, group_code: 'DOCS_DB_ODBC',
                       code: 'DOCS_DB_ODBC_QUERY_TIMEOUT', value: '45')

      expect(described_class.group('DOCS_DB_ODBC')['QUERY_TIMEOUT']).to eq('45')
    end

    # Es lo que permite que `Config` nombre exactamente los ajustes que faltan.
    it 'omite los que están sin valor' do
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_PORT', value: nil)

      expect(described_class.group('DOCS_DB_ODBC')).not_to have_key('PORT')
    end
  end

  describe '#update_value!' do
    it 'graba el valor y la auditoría' do
      setting = create(:setting, value: nil)

      setting.update_value!('nuevo')

      expect(setting.reload.value).to eq('nuevo')
      expect(setting.updated_by).to be_present
    end

    # Es lo que la pantalla necesita para "borrar" un ajuste: un campo vacío
    # tiene que quedar NULL, no como cadena vacía, para que `Setting.group` lo
    # reporte como no configurado.
    it 'normaliza el vacío a nil' do
      setting = create(:setting, :configured)

      setting.update_value!('')

      expect(setting.reload.value).to be_nil
    end

    it 'no toca los metadatos del catálogo' do
      setting = create(:setting, description: 'Original', is_visible: false)

      setting.update_value!('x')

      expect(setting.reload).to have_attributes(description: 'Original', is_visible: false)
    end
  end
end
