describe IdentityNationBuilder::NationBuilderMemberSyncPushSerializer do
  context 'serialize' do

    before(:each) do
      Settings.stub_chain(:options, :default_phone_country_code) { '61' }
      Settings.stub_chain(:options, :default_mobile_phone_national_destination_code) { 4 }
      Member.all.destroy_all
      Settings.stub_chain(:nation_builder) { {} }
      @member = FactoryBot.create(:member_with_both_phones)
      list = FactoryBot.create(:list)
      FactoryBot.create(:list_member, list: list, member: @member)
      FactoryBot.create(:member_with_both_phones)
      Settings.stub_chain(:options, :default_phone_country_code).and_return(nil)

      @batch_members = Member.all.in_batches.first
    end

    it 'returns valid object' do
      rows = ActiveModel::Serializer::CollectionSerializer.new(
        @batch_members,
        serializer: IdentityNationBuilder::NationBuilderMemberSyncPushSerializer
      ).as_json
      expect(rows.count).to eq(2)
      expect(rows[0][:email]).to eq(ListMember.first.member.email)
      expect(rows[0][:phone]).to eq(ListMember.first.member.phone_numbers.landline.first.phone)
      expect(rows[0][:mobile]).to eq(ListMember.first.member.phone_numbers.mobile.first.phone)
      expect(rows[0][:first_name]).to eq(ListMember.first.member.first_name)
      expect(rows[0][:last_name]).to eq(ListMember.first.member.last_name)
    end

    context 'with Settings.options.default_phone_country_code set' do
      let!(:country_code) { '61'}
      before { Settings.stub_chain(:options, :default_phone_country_code).and_return(country_code) }

      it 'returns valid object' do
        rows = ActiveModel::Serializer::CollectionSerializer.new(
          @batch_members,
          serializer: IdentityNationBuilder::NationBuilderMemberSyncPushSerializer
        ).as_json
        expect(rows[0][:phone]).to eq(@member.phone_numbers.landline.first.phone.gsub(/^#{country_code}/, '0'))
        expect(rows[0][:mobile]).to eq(@member.phone_numbers.mobile.first.phone.gsub(/^#{country_code}/, '0'))
      end
    end
  end
end
