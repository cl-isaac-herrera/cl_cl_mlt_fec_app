require 'rails_helper'

RSpec.describe Role, type: :model do
  it 'es válido con los atributos del factory' do
    expect(build(:role)).to be_valid
  end

  it 'soft_delete! lo desactiva sin borrarlo' do
    role = create(:role)

    role.soft_delete!

    expect(Role.exists?(role.id)).to be(false)
    expect(Role.unscoped.exists?(role.id)).to be(true)
  end
end
