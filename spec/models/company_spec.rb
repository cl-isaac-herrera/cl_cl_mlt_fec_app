require 'rails_helper'

RSpec.describe Company, type: :model do
  it 'es válida con los atributos del factory' do
    expect(build(:company)).to be_valid
  end

  # REGRESIÓN. El default era 0, que no es ninguna de las dos opciones del
  # `<select>` del formulario (1 legal / 2 comercial): al asignarle "0" el
  # navegador no encuentra la opción y deja el campo obligatorio SIN nada
  # seleccionado. Si el default vuelve a 0, este ejemplo falla.
  describe 'nombre para el envío de correos' do
    it 'nace en "nombre legal", que es una opción válida' do
      expect(Company.new(name: 'ACME').email_sender_type).to eq(1)
      expect(Company.new(name: 'ACME')).to be_valid
    end

    it 'rechaza un valor fuera de las dos opciones' do
      company = Company.new(name: 'ACME', email_sender_type: 0)

      expect(company).not_to be_valid
      expect(company.errors.full_messages)
        .to include('El nombre para el envío de correos no está incluido en la lista')
    end
  end

  describe 'bloque del emisor' do
    it 'acepta los cuatro tipos de identificación de Hacienda' do
      Company::ISSUER_ID_TYPES.each do |type|
        expect(build(:company, issuer_id_type: type)).to be_valid
      end
    end

    it 'rechaza un tipo de identificación que Hacienda no define' do
      company = build(:company, issuer_id_type: '99')

      expect(company).not_to be_valid
      expect(company.errors.full_messages)
        .to include('El tipo de identificación del emisor no está incluido en la lista')
    end

    # El largo replica el `Size` que el campo tenía como UDF de OADM.
    it 'rechaza una razón social más larga que 100 caracteres' do
      company = build(:company, issuer_legal_name: 'A' * 101)

      expect(company).not_to be_valid
      expect(company.errors.full_messages)
        .to include('La razón social del emisor es demasiado largo (máximo 100 caracteres)')
    end

    # 20 y no los 12 del UDF de OADM: ese `Size` no alcanzaba para el DIMEX ni
    # para el NITE, y desde que la identificación del emisor sale de acá el
    # recorte se llevaría puesto el comprobante.
    it 'acepta una identificación de hasta 20 caracteres' do
      expect(build(:company, issuer_id_number: '1' * 20)).to be_valid
    end

    it 'rechaza una identificación más larga que 20 caracteres' do
      company = build(:company, issuer_id_number: '1' * 21)

      expect(company).not_to be_valid
      expect(company.errors.full_messages)
        .to include('El número de identificación del emisor es demasiado largo (máximo 20 caracteres)')
    end

    it 'deja el bloque en blanco: una compañía puede estar configurada a medias' do
      expect(build(:company, issuer_legal_name: nil, issuer_id_type: nil,
                             issuer_id_number: nil)).to be_valid
    end
  end

  # `name` no es solo la etiqueta del selector: viaja en el XML como
  # `Emisor.NombreComercial`, y 80 es el máximo del esquema 4.4 de Hacienda.
  describe 'nombre comercial' do
    it 'acepta hasta 80 caracteres' do
      expect(build(:company, name: 'A' * 80)).to be_valid
    end

    it 'rechaza más de 80 caracteres' do
      company = build(:company, name: 'A' * 81)

      expect(company).not_to be_valid
      expect(company.errors.full_messages)
        .to include('El nombre es demasiado largo (máximo 80 caracteres)')
    end
  end

  it 'soft_delete! la desactiva sin borrarla' do
    company = create(:company)

    company.soft_delete!

    expect(Company.exists?(company.id)).to be(false)
    expect(Company.unscoped.exists?(company.id)).to be(true)
  end
end
