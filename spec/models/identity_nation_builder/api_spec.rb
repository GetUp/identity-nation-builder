require 'spec_helper'

describe IdentityNationBuilder::API do
  before do
    allow(Settings).to receive_message_chain(:nation_builder, :site).and_return('test')
    allow(Settings).to receive_message_chain(:nation_builder, :token).and_return('test')
    allow(Settings).to receive_message_chain(:nation_builder, :debug).and_return(false)
    allow(Settings).to receive_message_chain(:options, :default_mobile_phone_national_destination_code).and_return(4)
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

  describe '.find_or_create_person' do
    context 'with an invalid email' do
      let!(:invalid_email) { 'invalid@email' }
      let(:validation_failed_response) {
        {
          status: 400,
          headers: { 'Content-Type' => 'application/json' },
          body: {
            "code": "validation_failed",
            "message": "Validation Failed.",
            "validation_errors": [ "email 'test@invalid' should look like an email address" ]
          }.to_json
        }
      }
      let(:successful_response) {
        {
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { person: [ { "mobile": "0401000000" } ] }.to_json
        }
      }
      let!(:people_add_endpoint) {
        stub_request(:put, %r{people/add})
          .to_return { |request|
            if request.body.include?(invalid_email)
              validation_failed_response
            else
              successful_response
            end
          }
      }

      it 'should strip the email and retry' do
        IdentityNationBuilder::API.find_or_create_person({ "email": invalid_email })
        expect(people_add_endpoint).to have_been_requested.twice
      end
    end

    context "with a user whose mobile that matches a signup in NationBuilder" do
      let!(:mobile) { '0468519266' }
      let!(:people_add_endpoint) {
        stub_request(:put, %r{people/add}).and_return({ status: 400, body: {}.to_json})
      }
      let!(:member_data) {
        { mobile: mobile, phone: '1111111111', email: 'test@test.com' }
      }

      it 'should should match the record on mobile (without leading zero), return the id but not update the record' do
        people_match_endpoint = stub_request(:get, %r{people/match})
          .to_return { |request|
            expect(request.uri.query_values).to include('mobile')
            expect(request.uri.query_values['mobile']).to eq('468519266')
            {
              status: 200,
              headers: { 'Content-Type' => 'application/json' },
              body: { person: [ { "mobile": mobile } ] }.to_json
            }
          }
        IdentityNationBuilder::API.find_or_create_person(member_data)
        expect(people_match_endpoint).to have_been_requested
        expect(people_add_endpoint).to_not have_been_requested
      end
    end

    context "with a user without a mobile but whose phone that matches a signup in NationBuilder" do
      let!(:phone) { '0295700000' }
      let!(:people_add_endpoint) {
        stub_request(:put, %r{people/add}).and_return({ status: 400, body: {}.to_json})
      }
      let!(:member_data) {
        { mobile: '', phone: phone, email: 'test@test.com' }
      }

      it 'should should match the record on phone (with leading zero removed), return the id but not update the record' do
        people_match_endpoint = stub_request(:get, %r{people/match})
          .to_return { |request|
            expect(request.uri.query_values).to include('phone')
            expect(request.uri.query_values['phone']).to eq('295700000')
            {
              status: 200,
              headers: { 'Content-Type' => 'application/json' },
              body: { person: [ { "phone": phone } ] }.to_json
            }
          }
        IdentityNationBuilder::API.find_or_create_person(member_data)
        expect(people_match_endpoint).to have_been_requested
        expect(people_add_endpoint).to_not have_been_requested
      end
    end

    context "with hose mobile DOES NOT matches a signup in NationBuilder" do
      let!(:mobile) { '61468519266' }
      let!(:people_match_endpoint) {
        stub_request(:get, %r{people/match})
          .to_return { |request|
            {
              status: 400,
              headers: { 'Content-Type' => 'application/json' },
              body: { "code": "no_matches", "message": "No people matched the given criteria." }.to_json
            }
          }
      }
      let!(:people_add_endpoint) {
        stub_request(:put, %r{people/add}).and_return({
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { person: {mobile: mobile, first_name: "new user"}}.to_json
        })
      }
      let!(:member_data) {
        { mobile: mobile, phone: '1111111111', email: 'test@test.com' }
      }

      it 'should upsert the user' do
        IdentityNationBuilder::API.find_or_create_person(member_data)
        expect(people_match_endpoint).to have_been_requested
        expect(people_add_endpoint).to have_been_requested
      end
    end

    describe '.tag_list' do
      let!(:tag) { 'will: barnstorm' }

      it 'should url encode the tag' do
        tag_request = stub_request(:post, %r{lists/1/tag/will:%20barnstorm})
        IdentityNationBuilder::API.api(:lists, :add_tag, { list_id: 1, tag: tag })
        expect(tag_request).to have_been_requested
      end
    end

    describe '.rsvp' do
      let!(:identity_id) { 10 }
      let!(:nationbuilder_id) { 20 }
      let!(:event_id) { 30 }
      let!(:recruiter_id) { 40 }
      let!(:member) { { id: identity_id, mobile: '04000000000'} }
      let!(:person) { { id: nationbuilder_id, mobile: '04000000000'} }
      let!(:mark_as_attended) { true }

      context 'with no existing rsvp' do
        it 'should call the rsvp/create endpoint with attended set' do
          people_match_endpoint = stub_request(:get, %r{people/match})
            .to_return {
              {
                status: 200,
                headers: { 'Content-Type' => 'application/json' },
                body: { person: person }.to_json
              }
            }
          rsvp_request = stub_request(:post, %r{/sites/test/pages/events/30/rsvps})
            .with(body: hash_including(rsvp: { person_id: nationbuilder_id, attended: true, recruiter_id: recruiter_id}))
            .to_return({
              status: 200,
              headers: { 'Content-Type' => 'application/json' },
              body: { rsvp: { person_id: nationbuilder_id, attended: true }}.to_json
            })
          IdentityNationBuilder::API.rsvp('test', [member], event_id, mark_as_attended, recruiter_id) { |length, members|
            expect(length).to eq(1)
            expect(members).to eq([{ identity_id: identity_id, nationbuilder_id: nationbuilder_id }])
          }
          expect(people_match_endpoint).to have_been_requested
          expect(rsvp_request).to have_been_requested
        end
      end

      context 'with an existing rsvp' do
        it 'should update the rsvp if attended is set' do
          people_match_endpoint = stub_request(:get, %r{people/match})
            .to_return {
              {
                status: 200,
                headers: { 'Content-Type' => 'application/json' },
                body: { person: person }.to_json
              }
            }
          rsvp_create_request = stub_request(:post, %r{/sites/test/pages/events/30/rsvps})
            .with(body: hash_including(rsvp: { person_id: nationbuilder_id, attended: true}))
            .to_return({
              status: 400,
              headers: { 'Content-Type' => 'application/json' },
              body: {
                "code": "validation_failed",
                "message": "Validation Failed.",
                "validation_errors": [ "signup_id has already been taken" ]
              }.to_json
            })
          rsvp_list_request = stub_request(:get, %r{pages/events/30/rsvps})
            .to_return({
              status: 200,
              headers: { 'Content-Type' => 'application/json' },
              body: {
                results: [{ id: 12222, event_id: event_id, person_id: nationbuilder_id, attended: false }]
              }.to_json
            })
          rsvp_update_request = stub_request(:put, %r{pages/events/30/rsvps})
            .to_return({
              status: 200,
              headers: { 'Content-Type' => 'application/json' },
              body: {
                rsvp: { id: 12222, event_id: event_id, person_id: nationbuilder_id, attended: false }
              }.to_json
            })
          IdentityNationBuilder::API.rsvp('test', [member], event_id, mark_as_attended) { |length, members|
            expect(length).to eq(1)
            expect(members).to eq([{ identity_id: identity_id, nationbuilder_id: nationbuilder_id }])
          }
          expect(people_match_endpoint).to have_been_requested
          expect(rsvp_create_request).to have_been_requested
          expect(rsvp_list_request).to have_been_requested
          expect(rsvp_update_request).to have_been_requested
        end
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
