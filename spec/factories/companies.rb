FactoryBot.define do
  factory :company do
    sequence(:name) { |n| "Compañía #{n}" }
  end
end
