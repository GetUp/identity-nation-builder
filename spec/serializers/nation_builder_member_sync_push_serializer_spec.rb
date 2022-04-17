
$nb_id = 0

describe IdentityNationBuilder::NationBuilderMemberSyncPushSerializer do
  let!(:country_code) { '61' }

  before(:each) do
    allow(Settings).to(
      receive_message_chain(:options, :default_phone_country_code) { country_code }
    )
    allow(Settings).to(
      receive_message_chain(:options, :default_mobile_phone_national_destination_code) { '4' }
    )
  end

  context 'serialize' do
    before(:each) do
      Member.all.destroy_all
      @member = FactoryBot.create(:member_with_both_phones)
      list = FactoryBot.create(:list)
      FactoryBot.create(:list_member, list: list, member: @member)
      FactoryBot.create(:member_with_both_phones)

      @batch_members = Member.all.in_batches.first
    end

    it 'returns valid object' do
      rows = ActiveModel::Serializer::CollectionSerializer.new(
        @batch_members,
        serializer: IdentityNationBuilder::NationBuilderMemberSyncPushSerializer
      ).as_json
      expect(rows.count).to eq(2)
      expect(rows[0][:email]).to eq(ListMember.first.member.email)
      expect(rows[0][:phone]).to eq(ListMember.first.member.phone_numbers.landline.first.phone.gsub(/^#{country_code}/, '0'))
      expect(rows[0][:mobile]).to eq(ListMember.first.member.phone_numbers.mobile.first.phone.gsub(/^#{country_code}/, '0'))
      expect(rows[0][:first_name]).to eq(ListMember.first.member.first_name)
      expect(rows[0][:last_name]).to eq(ListMember.first.member.last_name)
    end

    context 'with Settings.options.default_phone_country_code set to nil' do
      before(:each) do
        allow(Settings).to receive_message_chain(:options, :default_phone_country_code) { nil }
      end

      it 'returns valid object' do
        rows = ActiveModel::Serializer::CollectionSerializer.new(
          @batch_members,
          serializer: IdentityNationBuilder::NationBuilderMemberSyncPushSerializer
        ).as_json
        expect(rows[0][:phone]).to eq(@member.phone_numbers.landline.first.phone)
        expect(rows[0][:mobile]).to eq(@member.phone_numbers.mobile.first.phone)
      end
    end

    context 'serialiser data equality' do
      let!(:equality_member) { FactoryBot.create(:member_with_mobile) }
      let!(:serialiser) {
        IdentityNationBuilder::NationBuilderMemberSyncPushSerializer.new(equality_member)
      }
      let!(:person_data) {
        # convert keys to strings since NB lib returns data with string keys
        Hash[serialiser.serializable_hash.map { |k,v| [k.to_s, v] }]
      }

      it 'returns true when compared for equality with own data' do
        expect(serialiser == person_data).to eq(true)
      end

      it 'returns false when compared for equality with different data' do
        different = person_data
        different['mobile'] = '555 1234'
        expect(serialiser == different).to eq(false)
      end

      it 'returns false when compared for equality with missing NB data' do
        missing = person_data.except('mobile')
        expect(serialiser == missing).to eq(false)
      end

      it 'returns false when compared for equality with missing Id data' do
        missing = person_data
        missing['phone'] = '555 1234'
        expect(serialiser == missing).to eq(false)
      end
    end
  end

  context 'temporal comparisons' do
    let!(:temporal_member) { FactoryBot.create(:member_with_mobile) }
    let!(:serialiser) {
      IdentityNationBuilder::NationBuilderMemberSyncPushSerializer.new(temporal_member)
    }
    let!(:newer_data) {
      data = serialiser.serializable_hash
      data['updated_at'] = (temporal_member.updated_at + 3660).to_s
      data
    }
    let!(:older_data) {
      data = serialiser.serializable_hash
      data['updated_at'] = (temporal_member.updated_at - 3660).to_s
      data
    }

    it 'returns true when newer_than compared with older data' do
      expect(serialiser.newer_than(older_data)).to eq(true)
    end

    it 'returns false when newer_than compared with newer data' do
      expect(serialiser.newer_than(newer_data)).to eq(false)
    end

    it 'returns true when older_than compared with newer data' do
      expect(serialiser.older_than(newer_data)).to eq(true)
    end

    it 'returns false when older_than compared with older data' do
      expect(serialiser.older_than(older_data)).to eq(false)
    end
  end

  context 'upsert using :merge' do
    before(:each) do
      allow(Settings).to(
        receive_message_chain(:options, :allow_subscribe_via_upsert_member) { true }
      )
      allow(Settings).to(
        receive_message_chain(:databases, :extensions_schemas, :core) { 'public' }
      )
    end

    let(:nb_id) { ($nb_id += 1).to_s }
    let!(:member) {
      member = FactoryBot.create(:member_with_both_phones)
      member.update_external_id('nation_builder', nb_id)
      member
    }
    let!(:serialiser) {
      IdentityNationBuilder::NationBuilderMemberSyncPushSerializer.new(member)
    }
    let!(:person_data) {
      # convert keys to strings since NB lib returns data with string keys
      data = Hash[serialiser.serializable_hash.map { |k,v| [k.to_s, v] }]
      data['id'] = nb_id
      data['updated_at'] = member.updated_at.to_s
      data
    }

    context 'identity is more recently updated' do
      before(:each) do
        member.updated_at = (member.updated_at + 3600)
      end

      it 'makes no change when no changes are present' do
        expect(UpsertMember).to receive(:new).at_most(0).times
        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(false)
        expect(serialiser).to eq(person_data)
      end

      it 'makes no change in id when id data is more recent' do
        member.update!(
          first_name: 'updated',
          last_name: 'updated',
        )

        expect(UpsertMember).to receive(:new).at_most(0).times
        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(false)

        # Will now be different than the person data
        expect(serialiser).not_to eq(person_data)
      end
    end

    context 'nationbuilder is more recently updated' do
      before(:each) do
        person_data['updated_at'] = (member.updated_at + 3600).to_s
      end

      it 'makes no change when no changes are present' do
        expect(UpsertMember).to receive(:new).at_most(0).times
        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(false)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member\'s given name' do
        person_data['first_name'] = 'updated first'

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member\'s family name' do
        person_data['last_name'] = 'updated last'

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member\'s full name' do
        person_data['first_name'] = 'updated first'
        person_data['middle_name'] = 'updated middle'
        person_data['last_name'] = 'updated last'

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member email' do
        person_data['email'] = 'updated@example.com'

        expect(UpsertMember).to(
          receive(:new).with(
            {
              email: 'updated@example.com',
              external_ids: { 'nation_builder' => person_data['id'] }
            },
            ignore_name_change: false,
            entry_point: 'nation_builder'
          ).and_call_original
        )

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'subscribes a member to email' do
        person_data['email_opt_in'] = true

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'unsubscribes a member from email' do
        member.subscribe_to(Subscription::EMAIL_SUBSCRIPTION)
        person_data['email_opt_in'] = false
        person_data['updated_at'] = (
          member.member_subscriptions.where(
            subscription: Subscription::EMAIL_SUBSCRIPTION
          ).first.updated_at + 3600
        ).to_s

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member mobile' do
        person_data['mobile'] = '0455123456'

        expect(UpsertMember).to(
          receive(:new).with(
            {
              phones: [{ phone: '0455123456' }],
              external_ids: { 'nation_builder' => person_data['id'] }
            },
            ignore_name_change: false,
            entry_point: 'nation_builder'
          ).and_call_original
        )

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'subscribes a member to sms' do
        person_data['mobile_opt_in'] = true

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'unsubscribes a member from sms' do
        member.subscribe_to(Subscription::SMS_SUBSCRIPTION)
        person_data['mobile_opt_in'] = false
        person_data['updated_at'] = (
          member.member_subscriptions.where(
            subscription: Subscription::SMS_SUBSCRIPTION
          ).first.updated_at + 3600
        ).to_s

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member landline' do
        person_data['phone'] = '0255551234'

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'subscribes a member to calls' do
        person_data['do_not_call'] = false

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'unsubscribes a member from calls' do
        member.subscribe_to(Subscription::CALLING_SUBSCRIPTION)
        person_data['do_not_call'] = true
        person_data['updated_at'] = (
          member.member_subscriptions.where(
            subscription: Subscription::CALLING_SUBSCRIPTION
          ).first.updated_at + 3600
        ).to_s

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member title' do
        person_data['prefix'] = 'test title'

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member gender' do
        person_data['sex'] = 'test gender'

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end

      it 'updates a member address' do
        person_data['home_address'] = {
          'address1' => 'Test 1',
          'address2' => 'Test 2',
          #'address3' => 'Test 3',
          'city' => 'Testing',
          'state' => 'TST',
          'zip' => '9999',
          'country_code' => 'TT',
        }

        expect(serialiser.upsert_from_person(person_data, :merge)).to eq(true)
        expect(serialiser).to eq(person_data)
      end
    end
  end
end
