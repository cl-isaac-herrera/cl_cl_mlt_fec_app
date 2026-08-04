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
end
