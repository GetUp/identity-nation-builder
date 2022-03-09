module IdentityNationBuilder
  class NationBuilderMemberSyncPushSerializer < ActiveModel::Serializer
    attributes :id, :nationbuilder_id, :email, :phone, :mobile, :first_name, :last_name

    def nationbuilder_id
      id = @object.member_external_ids.with_system(SYSTEM_NAME).first
      id.external_id if id
    end

    def phone
      number = @object.phone_numbers.landline.first
      strip_country_code(number.phone) if number
    end

    def mobile
      number = @object.phone_numbers.mobile.first
      strip_country_code(number.phone) if number
    end

    private

    def strip_country_code(phone)
      code = Settings.options.try(:default_phone_country_code)
      code ? phone.try(:gsub, /^#{code}/, '0') : phone
    end
  end
end
