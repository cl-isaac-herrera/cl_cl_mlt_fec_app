require 'rails_helper'

RSpec.describe UserRole, type: :model do
  it 'es válido con los atributos del factory (user, role y company)' do
    expect(build(:user_role)).to be_valid
  end

  it 'CompanyScoped — for_company filtra por company_id' do
    company_a = create(:company)
    company_b = create(:company)
    ur_a = create(:user_role, company: company_a)
    create(:user_role, company: company_b)

    expect(UserRole.for_company(company_a.id)).to contain_exactly(ur_a)
  end

  it 'no es válido sin compañía, y no explota contra la base' do
    user_role = build(:user_role, company: nil)

    expect(user_role).not_to be_valid
    expect(user_role.errors[:company]).to be_present
    expect { user_role.save }.not_to raise_error
  end
end
