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

    repetido = build(:user, email: 'dup@example.com')

    expect(repetido).not_to be_valid
    expect(repetido.errors.full_messages).to eq(['El correo ya está en uso'])
  end

  # El índice único de la tabla NO excluye a los inactivos, así que la validación
  # tampoco puede: sin `unscope`, el default_scope de SoftDeletable escondería al
  # homónimo dado de baja, la validación pasaría y explotaría la base.
  it 'tampoco lo permite cuando el homónimo está dado de baja' do
    create(:user, email: 'baja@example.com').soft_delete!

    expect(build(:user, email: 'baja@example.com')).not_to be_valid
  end

  it 'la base lo rechaza aunque se saltee el modelo' do
    create(:user, email: 'crudo@example.com')

    # `insert!` y no `insert`: este último trae `ON CONFLICT DO NOTHING` y se
    # tragaría el choque en silencio, que es justo lo contrario de lo que se prueba.
    expect { User.insert!({ email: 'crudo@example.com', is_active: true,
                            created_at: Time.current, updated_at: Time.current }) }
      .to raise_error(ActiveRecord::RecordNotUnique)
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
