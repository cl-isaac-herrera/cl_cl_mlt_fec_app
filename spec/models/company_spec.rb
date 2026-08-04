require 'rails_helper'

RSpec.describe Company, type: :model do
  it 'es válida con los atributos del factory' do
    expect(build(:company)).to be_valid
  end

  it 'soft_delete! la desactiva sin borrarla' do
    company = create(:company)

    company.soft_delete!

    expect(Company.exists?(company.id)).to be(false)
    expect(Company.unscoped.exists?(company.id)).to be(true)
  end
end
