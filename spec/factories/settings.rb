FactoryBot.define do
  factory :setting do
    sequence(:code) { |n| "TEST_GROUP_FIELD#{n}" }
    group_code      { 'TEST_GROUP' }
    description     { 'Ajuste de prueba' }
    is_visible      { true }
    value           { nil }

    # Ajuste oculto: el valor se escribe pero no se devuelve.
    trait :hidden do
      is_visible { false }
      value      { 's3cr3t' }
    end

    trait :configured do
      value { 'un-valor' }
    end
  end
end
