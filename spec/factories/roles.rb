FactoryBot.define do
  factory :role do
    sequence(:name) { |n| "Rol #{n}" }
  end
end
