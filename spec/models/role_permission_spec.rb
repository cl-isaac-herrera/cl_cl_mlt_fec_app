require 'rails_helper'

RSpec.describe RolePermission, type: :model do
  it 'es válido con los atributos del factory (role y permission)' do
    expect(build(:role_permission)).to be_valid
  end

  # docs/PLAN-ROLES-POR-ALCANCE.md: un rol solo puede contener permisos de su
  # propio alcance — un permiso de instalación en un rol de compañía (o al
  # revés) terminaría concediéndose por compañía o sin compañía, según el caso.
  it 'rechaza un permiso de alcance cruzado' do
    role       = create(:role, scope: 'company')
    permission = create(:permission, scope: 'installation')

    role_permission = build(:role_permission, role: role, permission: permission)

    expect(role_permission).not_to be_valid
    expect(role_permission.errors.full_messages)
      .to eq(['El permiso es de alcance installation y el rol es de alcance company'])
  end

  it 'permite el mismo alcance en los dos' do
    role       = create(:role, scope: 'installation')
    permission = create(:permission, scope: 'installation')

    expect(build(:role_permission, role: role, permission: permission)).to be_valid
  end
end
