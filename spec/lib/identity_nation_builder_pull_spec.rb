require 'rails_helper'

describe IdentityNationBuilder do
  context '#pull' do
    before(:each) do
      allow(Settings).to receive_message_chain(:app, :inbound_url).and_return("https://example.com/")
      clean_external_database
      @sync_id = 1
      @external_system_params = JSON.generate({'pull_job' => 'fetch_new_events'})
    end

    context 'with valid parameters' do
      it 'should call the corresponding method'  do
        expect(IdentityNationBuilder).to receive(:fetch_new_events).exactly(1).times.with(1)
        IdentityNationBuilder.pull(@sync_id, @external_system_params)
      end
    end
  end

  context '#fetch_new_events' do
    let!(:events_response){ JSON.parse(File.read("spec/fixtures/events_response.json")) }
    let!(:event_rsvp_response){ JSON.parse(File.read("spec/fixtures/event_rsvp_response.json")) }
    let!(:person_response){ JSON.parse(File.read("spec/fixtures/person_response.json")) }
    let!(:person_mobileonly_response){ JSON.parse(File.read("spec/fixtures/person_mobileonly_response.json")) }

    before(:each) do
      allow(Settings).to receive_message_chain(:app, :inbound_url).and_return("https://example.com/")
      clean_external_database

      Settings.stub_chain(:options, :default_phone_country_code) { '61' }
      Settings.stub_chain(:options, :default_mobile_phone_national_destination_code) { 4 }

      IdentityNationBuilder::API.stub_chain(:sites_events) { events_response["results"] }
    end

    context 'with SideKiq inline' do
      let!(:campaign) { FactoryBot.create(:campaign) }

      before(:each) do
        allow(Settings).to receive_message_chain(:nation_builder, :default_event_campaign_id).and_return(campaign.id)
        allow(Settings).to receive_message_chain(:options, :allow_subscribe_via_upsert_member).and_return(true)
        allow(Settings).to receive_message_chain(:options, :default_member_opt_in_subscriptions).and_return(true)
        IdentityNationBuilder::API.stub_chain(:all_event_rsvps) { event_rsvp_response["results"] }
        IdentityNationBuilder::API.stub_chain(:person) { person_response["person"] }
      end

      before(:all) do
        Sidekiq::Testing.inline!
      end

      after(:all) do
        Sidekiq::Testing.fake!
      end

      it 'should fetch the new events and insert them' do
        IdentityNationBuilder.fetch_new_events(@sync_id) {}
        expect(Event.count).to eq(2)
      end

      it 'should call the api' do
        IdentityNationBuilder::API.should_receive(:all_event_rsvps).exactly(2).times.with(anything, anything)
        IdentityNationBuilder::API.should_receive(:person).exactly(6).times.with(anything)
        IdentityNationBuilder.fetch_new_events(@sync_id) {}
      end

      it 'should record all event details' do
        IdentityNationBuilder.fetch_new_events(@sync_id) {}
        nb_event = events_response["results"][0]
        event_location = IdentityNationBuilder.event_address_full(nb_event)
        expect(Event.first).to have_attributes(
          name: nb_event['name'],
          start_time: nb_event['start_time'] && DateTime.parse(nb_event['start_time']),
          end_time: nb_event['end_date'] && DateTime.parse(nb_event['end_date']),
          description: nb_event['intro'],
          location: event_location,
          latitude: Float(nb_event['venue']['address']['lat']),
          longitude: Float(nb_event['venue']['address']['lng']),
          max_attendees: Integer(nb_event['capacity']),
          approved: nb_event['status'] == 'published',
          invite_only: !nb_event['rsvp_form']['allow_guests'],
          data: nb_event
        )
      end

      context 'with an existing event updated in the past' do
        it 'should update the updated_at even if the values have not changed' do
          IdentityNationBuilder.fetch_new_events(@sync_id) {}
          Event.update_all(updated_at: 3.days.ago)
          IdentityNationBuilder.fetch_new_events(@sync_id) {}
          expect(Event.first.updated_at.to_date).to eq(Date.today)
        end
      end

      context 'with an existing event that is in the time period but not returned by the api' do
        let!(:removed_event){ Event.create!(
          system: IdentityNationBuilder::SYSTEM_NAME,
          name: "Existing event",
          subsystem: 'action',
          campaign_id: campaign.id,
          start_time: Time.now,
          updated_at: 4.days.ago,
          id: 9999,
          data: { status: 'published' }
        )}

        it 'should set the the removed_at within the data field' do
          IdentityNationBuilder.fetch_new_events(@sync_id) {}
          removed_event.reload
          expect(removed_event.data['status']).to eq('removed')
        end
      end

      it 'should fetch people and upsert members' do
        IdentityNationBuilder.fetch_new_events(@sync_id) {}
        expect(Member.count).to eq(1)
      end

      it 'should record member details' do
        IdentityNationBuilder.fetch_new_events(@sync_id) {}
        expect(Member.last).to have_attributes(
          first_name: person_response['person']['first_name'],
          last_name: person_response['person']['last_name'],
          email: person_response['person']['email'],
          phone: person_response['person']['phone'] || person_response['person']['mobile']
        )
      end

      it 'should fetch the new event rsvps and insert them' do
        IdentityNationBuilder.fetch_new_events(@sync_id) {}
        expect(EventRsvp.count).to eq(2)
        event = Event.where(external_id: 1).first
        event_rsvp = EventRsvp.where(event_id: event.id).first
        json_from_nb = event_rsvp_response["results"][2]
        expect(event_rsvp.data).to eq(json_from_nb)
      end
    end

    context 'with an event without an address' do
      let!(:campaign) { FactoryBot.create(:campaign) }

      it 'should use the event name as the location' do
        allow(Settings).to receive_message_chain(:nation_builder, :default_event_campaign_id).and_return(campaign.id)
        allow(IdentityNationBuilder).to receive(:fetch_new_event_rsvps).and_return(event_rsvp_response)
        Sidekiq::Testing.fake!
        events_without_venue_address = events_response['results']
        events_without_venue_address.first['venue'].delete('address')
        IdentityNationBuilder::API.stub(:sites_events).and_return(events_without_venue_address)

        IdentityNationBuilder.fetch_new_events(@sync_id) {}
        event = Event.first
        expect(event.location).to include(events_without_venue_address.first['venue']['name'])
        expect(event.latitude).to be_nil
        expect(event.longitude).to be_nil
      end
    end

    context 'person with mobile only' do
      before(:all) do
        Sidekiq::Testing.inline!
      end

      before(:each) do
        allow(Settings).to receive_message_chain(:app, :inbound_url).and_return("https://example.com/")
        clean_external_database

        IdentityNationBuilder::API.stub_chain(:all_event_rsvps) { event_rsvp_response["results"] }
        IdentityNationBuilder::API.stub_chain(:person) { person_mobileonly_response["person"] }

        IdentityNationBuilder::API.should_receive(:all_event_rsvps).exactly(2).times.with(anything, anything)
        IdentityNationBuilder::API.should_receive(:person).exactly(6).times.with(anything)
      end

      it 'should record details of member who only has a mobile number' do
        campaign =  FactoryBot.create(:campaign)
        allow(Settings).to receive_message_chain(:nation_builder, :default_event_campaign_id).and_return(campaign.id)
        allow(Settings).to receive_message_chain(:options, :allow_subscribe_via_upsert_member).and_return(true)
        allow(Settings).to receive_message_chain(:options, :default_member_opt_in_subscriptions).and_return(true)

        mobile_last_three_digits = person_mobileonly_response['person']['mobile'].from(-3)
        IdentityNationBuilder.fetch_new_events(@sync_id) {}
        expect(Member.last).to have_attributes(
          first_name: person_mobileonly_response['person']['first_name'],
          last_name: person_mobileonly_response['person']['last_name'],
          email: person_mobileonly_response['person']['email'],
        )
        expect(Member.last.phone).to include(mobile_last_three_digits)
      end
    end
  end
end
