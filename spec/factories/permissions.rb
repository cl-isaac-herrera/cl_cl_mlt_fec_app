FactoryBot.define do
  factory :permission do
    sequence(:name) { |n| "Module_Resource_Action#{n}" }
    description { 'Permiso de prueba' }
  end
end
