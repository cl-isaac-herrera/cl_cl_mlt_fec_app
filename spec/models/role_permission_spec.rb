require 'rails_helper'

RSpec.describe RolePermission, type: :model do
  it 'es válido con los atributos del factory (role y permission)' do
    expect(build(:role_permission)).to be_valid
  end
end
