module IdentityNationBuilder
  class NationBuilderMemberSyncPushSerializer < ActiveModel::Serializer

    attributes :prefix, :first_name, :middle_name, :last_name, :sex,
               :email, :email_opt_in,
               :mobile, :mobile_opt_in,
               :phone, :do_not_call,
               :home_address

    def prefix
      @object.title
    end

    def middle_name
      @object.middle_names
    end

    def sex
      @object.gender
    end

    def email_opt_in
      @object.is_subscribed_to?(Subscription::EMAIL_SUBSCRIPTION)
    end

    def mobile
      number = @object.phone_numbers.mobile.first
      strip_country_code(number.phone) if number
    end

    def mobile_opt_in
      @object.is_subscribed_to?(Subscription::SMS_SUBSCRIPTION)
    end

    def phone
      number = @object.phone_numbers.landline.first
      strip_country_code(number.phone) if number
    end

    def do_not_call
      !@object.is_subscribed_to?(Subscription::CALLING_SUBSCRIPTION)
    end

    def home_address
      address = @object.addresses.first
      {
        'address1' => address.line1,
        'address2' => address.line2,
        #'address3' => address.line3,
        'city' => address.town,
        'state' => address.state,
        'zip' => address.postcode,
        'country_code' => address.country,
      } if address
    end

    def upsert_from_person(person_data, type)
      was_upserted = false
      #ApplicationRecord.transaction do
        id_data = serializable_hash
        person_updated = Time.parse(person_data['updated_at'])
        upsert_data = {}

        id_updated_later = -> (attribute_name) {
          if attribute_name == 'email_opt_in'
            subscription_updated_after?(Subscription::EMAIL_SUBSCRIPTION, person_updated)
          elsif attribute_name == 'mobile'
            object_updated_after?(@object.phone_numbers.mobile.first, person_updated)
          elsif attribute_name == 'mobile_opt_in'
            subscription_updated_after?(Subscription::SMS_SUBSCRIPTION, person_updated)
          elsif attribute_name == 'phone'
            object_updated_after?(@object.phone_numbers.landline.first, person_updated)
          elsif attribute_name == 'do_not_call'
            subscription_updated_after?(Subscription::CALLING_SUBSCRIPTION, person_updated)
          elsif attribute_name == 'home_address'
            object_updated_after?(@object.addresses.first, person_updated)
          else
            object_updated_after?(@object, person_updated)
          end
        }

        # Handle merging or not

        # Takes the most recently modified object value unless it is
        # empty/nill, otherwise takes the other object's value.
        update_upsert_merge = -> (key, attribute_name, &block) {
          id_value = id_data[attribute_name.to_sym]
          nb_value = person_data[attribute_name]

          if valid?(id_value) && valid?(nb_value)
            value = id_updated_later::(attribute_name) ? id_value : nb_value
          elsif valid?(id_value)
            value = id_value
          else
            value = nb_value
          end

          # only actually upsert if the value has changed
          if value != id_value
            value = block::(value, upsert_data[key]) if block
            upsert_data[key] = value
          end
        }

        # Takes the most recently modified object value, even if
        # empty. This allows values to be removed and this to be
        # reflected at the other end.
        update_upsert_overwrite = ->(key, attribute_name, &block) {
          id_value = id_data[attribute_name.to_sym]
          nb_value = person_data[attribute_name]

          value = id_updated_later::(attribute_name) ? id_value : nb_value

          # only actually upsert if the value has changed
          if value != id_value
            value = block::(value, upsert_data[key]) if block
            upsert_data[key] = value
          end
        }

        case type
        when :merge
          update_upsert = update_upsert_merge
        when :overwrite
          update_upsert = update_upsert_overwrite
        else
          raise RuntimeError('unknown upsert type')
        end

        # Work out what all supported upsert values should actually be

        update_upsert::(:firstname, 'first_name')
        update_upsert::(:middlenames, 'middle_name')
        update_upsert::(:lastname, 'last_name')

        # id will erase the other name parts if present, so need to
        # set all of them if any

        update_upsert::(:title, 'prefix')
        update_upsert::(:gender, 'sex')

        update_upsert::(:email, 'email')
        update_upsert::(:phones, 'mobile') { |number, phones|
          phones = [] if !phones
          phones.append({ phone: number })
          phones
        }
        update_upsert::(:phones, 'phone') { |number, phones|
          phones = [] if !phones
          phones.append({ phone: number })
          phones
        }

        update_upsert::(:subscriptions, 'email_opt_in') { |opt_in, subscriptions|
          subscriptions = [] if !subscriptions
          subscriptions.append(
            {
              slug: Subscription::EMAIL_SLUG,
              action: opt_in ? 'subscribe' : 'unsubscribe',
              reason: SYSTEM_NAME
            }
          )
        }
        update_upsert::(:subscriptions, 'mobile_opt_in') { |opt_in, subscriptions|
          subscriptions = [] if !subscriptions
          subscriptions.append(
            {
              slug: Subscription::SMS_SLUG,
              action: opt_in ? 'subscribe' : 'unsubscribe',
              reason: SYSTEM_NAME
            }
          )
        }
        update_upsert::(:subscriptions, 'do_not_call') { |opt_out, subscriptions|
          subscriptions = [] if !subscriptions
          subscriptions.append(
            {
              slug: Subscription::CALLING_SLUG,
              action: opt_out ? 'unsubscribe' : 'subscribe',
              reason: SYSTEM_NAME
            }
          )
        }

        update_upsert::(:addresses, 'home_address') { |address, addresses|
          addresses = [] if !addresses
          addresses.append(
            {
              line1: address['address1'],
              line2: address['address2'],
              #line3: address['address3'],
              town: address['city'],
              state: address['state'],
              postcode: address['zip'],
              country: address['country_code'],
            }
          )
        }

        if !upsert_data.empty?
          member = UpsertMember::(
            upsert_data.merge(external_ids: { SYSTEM_NAME => person_data['id'] }),
            ignore_name_change: false,
            entry_point: SYSTEM_NAME,
          )
          was_upserted = true

          # XXX extend UpsertMember to support these
          if upsert_data.has_key?(:email)
            member.update!(email: upsert_data[:email])
          end
          if upsert_data.has_key?(:title)
            member.update!(title: upsert_data[:title])
          end
          if upsert_data.has_key?(:gender)
            member.update!(gender: upsert_data[:gender])
          end

          @object = member
        end
      #end

      was_upserted
    end

    def attribute_equal(attribute_name, person_data)
      return send(attribute_name) == person_data[attribute_name]
    end

    def ==(person_data)
      id_data = serializable_hash

      equal = true
      attributes.each { |attr,value|
        equal = id_data[attr] == person_data[attr.to_s]
        break unless equal
      }
      equal
    end

    def newer_than(person_data)
      person_updated = person_data['updated_at']
      @object.updated_at > Time.parse(person_updated) if person_updated
    end

    def older_than(person_data)
      person_updated = person_data['updated_at']
      @object.updated_at < Time.parse(person_updated) if person_updated
    end

    private

    def strip_country_code(phone)
      code = Settings.options.try(:default_phone_country_code)
      code ? phone.try(:gsub, /^#{code}/, '0') : phone
    end

    def object_updated_after?(object, time)
      valid?(object) && object.updated_at > time
    end

    def subscription_updated_after?(subscription_type, time)
      sub = @object.member_subscriptions.where(
        subscription: subscription_type
      ).first
      !sub.nil? && sub.updated_at > time
    end

    def valid?(value)
      return !value.nil? && value != ''
    end
  end
end
