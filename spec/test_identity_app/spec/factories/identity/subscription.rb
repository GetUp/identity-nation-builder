FactoryBot.define do
  factory :subscription do
    factory :email_subscription do
      id { Subscription::EMAIL_SUBSCRIPTION }
      name { 'Email' }
    end
    factory :calling_subscription do
      id { Subscription::CALLING_SUBSCRIPTION }
      name { 'Calling' }
    end
    factory :sms_subscription do
      id { Subscription::SMS_SUBSCRIPTION }
      name { 'Texting' }
    end
  end
end
