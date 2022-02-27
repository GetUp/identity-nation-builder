FactoryBot.define do
  factory :campaign do
    name { Faker::Book.title }
  end
end
