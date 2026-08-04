require 'rails_helper'

RSpec.describe User, type: :model do
  it 'es válido con los atributos del factory' do
    expect(build(:user)).to be_valid
  end

  it 'nace activo y con created_by/updated_by poblados por Auditable' do
    user = create(:user)

    expect(user.is_active).to be(true)
    expect(user.created_by).to eq('system')
  end

  it 'no permite dos usuarios con el mismo email' do
    create(:user, email: 'dup@example.com')

    expect { create(:user, email: 'dup@example.com') }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe 'SoftDeletable' do
    it 'soft_delete! desactiva en vez de borrar, y desaparece del scope por default' do
      user = create(:user)

      user.soft_delete!

      expect(User.exists?(user.id)).to be(false)
      expect(User.unscoped.exists?(user.id)).to be(true)
    end
  end
end
