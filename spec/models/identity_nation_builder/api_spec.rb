require 'spec_helper'

$nb_id = 0

describe IdentityNationBuilder::API do
  before do
    allow(Settings).to receive_message_chain(:nation_builder, :site).and_return('test_site')
    allow(Settings).to receive_message_chain(:nation_builder, :token).and_return('test_token')
    allow(Settings).to receive_message_chain(:nation_builder, :author_id).and_return(1234)
    allow(Settings).to receive_message_chain(:nation_builder, :debug).and_return(true)
    allow(Settings).to(
      receive_message_chain(:options, :default_phone_country_code) { country_code }
    )
    allow(Settings).to(
      receive_message_chain(:options, :default_mobile_phone_national_destination_code) { '4' }
    )
    allow(Settings).to(
      receive_message_chain(:options, :allow_subscribe_via_upsert_member) { true }
    )
  end

  describe 'person_upsert' do
    let(:nb_id) { ($nb_id += 1) }

    context 'a member with a nationbuilder id' do
      let!(:member_with_email) {
        member = FactoryBot.create(:member)
        member.update_external_id('nation_builder', nb_id)
        member
      }
      let!(:person_with_email) {
        serialiser = IdentityNationBuilder::PersonSerializer.new(member_with_email)
        # convert keys to strings since NB lib returns data with string keys
        data = Hash[serialiser.serializable_hash.map { |k,v| [k.to_s, v] }]
        data['id'] = nb_id
        data['updated_at'] = member_with_email.updated_at.to_s
        data
      }
      let(:updated_at_earlier) { (member_with_email.updated_at - 60).to_s }
      let(:updated_at_later) { (member_with_email.updated_at + 60).to_s }

      it 'update member in Identity when NB more recently updated' do
        match = stub_request(
          :get, 'https://test_site.nationbuilder.com/api/v1/people/' + nb_id.to_s
        ).to_return(
          status: 200,
          headers: { 'Content-Type': 'application/json' },
          body: {
            'person': person_with_email.update({
              'first_name': 'updated_test_name',
              'updated_at': updated_at_later
            })
          }.to_json
        )

        person_id = IdentityNationBuilder::API.person_upsert(member_with_email)

        expect(match).to have_been_made.times(1)
        expect(person_id).to eq(nb_id)
        expect(member_with_email.first_name).to eq('updated_test_name')
        expect(member_with_email.member_external_ids.with_system('nation_builder').first).to eq(1000)
      end
    end

    context 'a member without a nationbuilder id' do
      let(:updated_at_earlier) { (member_with_email.updated_at - 60).to_s }
      let(:updated_at_later) { (member_with_email.updated_at + 60).to_s }

      it 'should find a more recently modified person in NB by email and update Id' do
        match = stub_request(:get, 'https://test_site.nationbuilder.com/api/v1/people/match')
          .with(query: hash_including({ email: @member_with_email.email}))
          .to_return(
            status: 200,
            headers: { 'Content-Type': 'application/json' },
            body: {
              'person': {
                'id': 1000,
                'email': 'updated@test.com',
                'updated_at': updated_at_later,
              }
            }.to_json
          )

        person_id = IdentityNationBuilder::API.person_upsert(member_with_email)

        expect(match).to have_been_made.times(1)
        expect(person_id).to eq(1000)
        expect(member_with_email.email).to eq('updated@test.com')
        expect(member_with_email.member_external_ids.with_system('nation_builder').first).to eq(1000)
      end

      it 'should find a less recently modified person in NB by email and update both' do
        match = stub_request(:get, 'https://test_site.nationbuilder.com/api/v1/people/match')
          .with(query: hash_including({ email: @member_with_email.email}))
          .to_return(
            status: 200,
            headers: { 'Content-Type': 'application/json' },
            body: {
              'person': {
                'id': 1000,
                'email': 'previously@test.com',
                'updated_at': updated_at_earlier,
              }
            }.to_json
          )
        create = stub_request(:put, 'https://test_site.nationbuilder.com/api/v1/people/1000')
          .to_return(
            status: 201,
            headers: { 'Content-Type': 'application/json' },
            body: {
              'person': {
                'id': 1000,
                'email': @member_with_email.email,
              }
            }.to_json
          )
        
        person_id = IdentityNationBuilder::API.person_upsert(@member_with_email)

        expect(match).to have_been_made.times(1)
        expect(create).to have_been_made.times(1)
        expect(person_id).to eq(1000)
        expect(id_member.member_external_ids.with_system('nation_builder').first).to eq(1000)
      end

      it 'should upsert an existing member with a mobile' do
        mobile = @member_with_mobile.phone_numbers.mobile.first.phone.gsub(/^61/, '0')
        match = stub_request(:get, 'https://test_site.nationbuilder.com/api/v1/people/match')
          .with(query: hash_including({ mobile: mobile }))
          .to_return(
            status: 200,
            headers: { 'Content-Type': 'application/json' },
            body: {
              'person': { 'id': 1000 }
            }.to_json
          )
        create = stub_request(:put, 'https://test_site.nationbuilder.com/api/v1/people/1000')
          .to_return(
            status: 201,
            headers: { 'Content-Type': 'application/json' },
            body: {
              'person': { 'id': 1000 }
            }.to_json
          )
        
        person_id = IdentityNationBuilder::API.person_upsert(@member_with_mobile)

        expect(match).to have_been_made.times(1)
        expect(create).to have_been_made.times(1)
        expect(person_id).to eq(1000)
      end

      it 'should upsert an existing member with a landline' do
        landline = @member_with_landline.phone_numbers.landline.first.phone.gsub(/^61/, '0')
        match = stub_request(:get, %r{/api/v1/people/match})
          .with(query: hash_including({ phone: landline }))
          .to_return(
            status: 200,
            headers: { 'Content-Type': 'application/json' },
            body: {
              'person': { 'id': 1000 }
            }.to_json
          )
        create = stub_request(:put, 'https://test_site.nationbuilder.com/api/v1/people/1000')
          .to_return(
            status: 201,
            headers: { 'Content-Type': 'application/json' },
            body: {
              'person': { 'id': 1000 }
            }.to_json
          )
        
        person_id = IdentityNationBuilder::API.person_upsert(@member_with_landline)

        expect(match).to have_been_made.times(1)
        expect(create).to have_been_made.times(1)
        expect(person_id).to eq(1000)
      end
    end
  end

  describe 'lists' do
    it 'list_create should a create new list' do
      create = stub_request(:post, 'https://test_site.nationbuilder.com/api/v1/lists')
        .with(body: hash_including({ list: { name: 'Test List', slug: 'test_list', author_id: 1234} }))
        .to_return(
          status: 201,
          headers: { 'Content-Type': 'application/json' },
          body: {
            "list_resource": {
              "id": 12,
              "name": "Test List",
              "slug": "test_list",
            }
          }.to_json
        )
        
      list_id = IdentityNationBuilder::API.list_create('Test List')

      expect(create).to have_been_made.times(1)
      expect(list_id).to eq(12)
    end

    it 'list_create should raise an error if a list exists' do
      create = stub_request(:post, 'https://test_site.nationbuilder.com/api/v1/lists')
        .with(body: hash_including({ list: { name: 'Test List', slug: 'test_list', author_id: 1234} }))
        .to_return(
          status: 400,
          headers: { 'Content-Type': 'application/json' },
          body: {
            "code": "validation_failed",
            "message": "Validation Failed.",
            "validation_errors": [ "slug has already been taken" ]
          }.to_json
        )
        
      expect { IdentityNationBuilder::API.list_create('Test List')  }
        .to raise_error(NationBuilder::ClientError)
      expect(create).to have_been_made.times(1)
    end

    it 'list_find should return the list if found' do
      get = stub_request(:get, 'https://test_site.nationbuilder.com/api/v1/lists')
        .with(query: hash_including({ per_page: '100' }))
        .to_return(
          status: 200,
          headers: { 'Content-Type': 'application/json' },
          body: {
            "next": nil,
            "prev": nil,
            "results": [
              {
                "id": 10,
                "name": "Test List",
                "slug": "test_list",
                "author_id": 1,
                "count": 5
              }
            ]
          }.to_json
        )
        
      list_id = IdentityNationBuilder::API.list_find('Test List')

      expect(get).to have_been_made.times(1)
      expect(list_id).to eq(10)
    end

    it 'list_find should raise an error if the list is not found' do
      get = stub_request(:get, 'https://test_site.nationbuilder.com/api/v1/lists')
        .with(query: hash_including({ per_page: '100' }))
        .to_return(
          status: 200,
          headers: { 'Content-Type': 'application/json' },
          body: {
            "next": nil,
            "prev": nil,
            "results": [
              {
                "id": 10,
                "name": "Test List",
                "slug": "test_list",
                "author_id": 1,
                "count": 5
              }
            ]
          }.to_json
        )
        
      expect { IdentityNationBuilder::API.list_find('Other List') }
        .to raise_error(RuntimeError)
      expect(get).to have_been_made.times(1)
    end

    it 'list_add_people create should add ids' do
      add = stub_request(:post, 'https://test_site.nationbuilder.com/api/v1/lists/100/people')
        .with(body: hash_including({ people_ids: [1, 2, 3] }))
        .to_return(
          status: 201,
          headers: { 'Content-Type': 'application/json' },
          body: {
            "id": 100,
            "name": "Test List",
            "slug": "test_list",
          }.to_json
        )
        
      list_id = IdentityNationBuilder::API.list_add_people(100, [1, 2, 3])

      expect(add).to have_been_made.times(1)
      expect(list_id).to eq(100)
    end
  end

  describe '.sites_events' do
    let!(:sites_request) {
      stub_request(:get, %r{sites})
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { results: [ { "id": 1, "slug": "test" } ] }.to_json
        )
    }
    let!(:events_request) {
      stub_request(:get, %r{events})
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { results: [ { "id": 2, "name": "test event", "site_slug": "test" } ] }.to_json
        )
    }

    describe '.cached_sites' do
      it "should return a list of cached sites from NationBuilder" do
        IdentityNationBuilder::API.sites_events
        expect(IdentityNationBuilder::API.cached_sites.length).to eq(1)
        expect(IdentityNationBuilder::API.cached_sites.first['slug']).to eq('test')
      end
    end

    describe '.cached_sites_events' do
      it "should return a list of cached sites from NationBuilder" do
        IdentityNationBuilder::API.sites_events
        expect(IdentityNationBuilder::API.cached_sites_events.length).to eq(1)
        expect(IdentityNationBuilder::API.cached_sites_events.first['name']).to eq('test event')
      end
    end
  end

  describe '.recruiters' do
    let!(:organisations) { [ { id: 1, last_name: 'Recruiter 1' }, { id: 2, last_name: 'Recruiter 2' } ] }
    let!(:tags_endpoint) {
      stub_request(:get, %r{tags/recruiter/people})
        .to_return { |request|
          {
            status: 200,
            headers: { 'Content-Type' => 'application/json' },
            body: { results: organisations }.to_json
          }
        }
    }

    it 'should return a list of organisations tagged as recruiter' do
      recruiters = IdentityNationBuilder::API.recruiters
      expect(tags_endpoint).to have_been_requested
      expect(recruiters.length).to eq(2)
      expect(recruiters[0].first).to eq('Recruiter 1')
      expect(recruiters[0].last).to eq(1)
    end

    it 'should cache the recruiters' do
      recruiters = IdentityNationBuilder::API.recruiters
      expect(IdentityNationBuilder::API.cached_recruiters).to eq(recruiters)
    end
  end
end
