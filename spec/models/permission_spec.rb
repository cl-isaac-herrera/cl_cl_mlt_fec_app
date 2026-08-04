require 'rails_helper'

RSpec.describe Permission, type: :model do
  it 'es válido con los atributos del factory' do
    expect(build(:permission)).to be_valid
  end

  it 'soft_delete! lo desactiva sin borrarlo' do
    permission = create(:permission)

    permission.soft_delete!

    expect(Permission.exists?(permission.id)).to be(false)
    expect(Permission.unscoped.exists?(permission.id)).to be(true)
  end
end
