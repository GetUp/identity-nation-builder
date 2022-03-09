require 'active_record'

module ExternalDatabaseHelpers
  class << self
    def set_external_database_urls(database_url)
      ENV['IDENTITY_DATABASE_URL'] = database_url
      ENV['IDENTITY_READ_ONLY_DATABASE_URL'] = database_url
    end

    def setup
    ensure
      ActiveRecord::Base.establish_connection ENV['IDENTITY_DATABASE_URL']
    end

    def clean
      MemberExternalId.all.destroy_all
      Event.all.destroy_all
      Campaign.all.destroy_all
      PhoneNumber.all.destroy_all
      ListMember.all.destroy_all
      List.all.destroy_all
      Member.all.destroy_all
      MemberSubscription.all.destroy_all
      Subscription.all.destroy_all
      Contact.all.destroy_all
      ContactCampaign.all.destroy_all
      ContactResponseKey.all.destroy_all
      ContactResponse.all.destroy_all
      CustomField.all.destroy_all
      CustomFieldKey.all.destroy_all
      Search.all.destroy_all
    end
  end
end
