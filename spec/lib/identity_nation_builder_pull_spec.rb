require 'rails_helper'

describe IdentityNationBuilder do
  context 'fetching new events' do

    let!(:events_response){ JSON.parse(File.read("spec/fixtures/events_response.json")) }
    let!(:event_rsvp_response){ JSON.parse(File.read("spec/fixtures/event_rsvp_response.json")) }
    let!(:person_response){ JSON.parse(File.read("spec/fixtures/person_response.json")) }

    before(:each) do
      IdentityNationBuilder::API.should_receive(:sites_events).and_return(events_response["results"])
      IdentityNationBuilder::API.should_receive(:all_event_rsvps).exactly(2).times.with(anything, anything).and_return(event_rsvp_response["results"])
      IdentityNationBuilder::API.should_receive(:person).exactly(6).times.with(anything).and_return(person_response["person"])
    end

    it 'should fetch the new events and insert them' do
      IdentityNationBuilder.fetch_new_events
      expect(Event.count).to eq(2)
    end

    it 'should record all event details' do
      IdentityNationBuilder.fetch_new_events
      nb_event = events_response["results"][0]
      event_location = "#{nb_event['venue']['name']} - #{nb_event['venue']['address']['address1']} #{nb_event['venue']['address']['address2']} #{nb_event['venue']['address']['address3']}, #{nb_event['venue']['address']['city']}, #{nb_event['venue']['address']['state']}, #{nb_event['venue']['address']['country_code']}"
      expect(Event.first).to have_attributes(
        name: nb_event['name'],
        start_time: DateTime.parse(nb_event['start_time']),
        end_time: DateTime.parse(nb_event['end_time']),
        description: nb_event['intro'],
        location: event_location,
        latitude: Float(nb_event['venue']['address']['lat']),
        longitude: Float(nb_event['venue']['address']['lng']),
        max_attendees: Integer(nb_event['capacity']),
        approved: nb_event['status'] == 'published',
        invite_only: !nb_event['rsvp_form']['allow_guests']
      )
    end

    it 'should fetch people and upsert members' do
      IdentityNationBuilder.fetch_new_events
      expect(Member.count).to eq(1)
    end

    it 'should record member details' do
      IdentityNationBuilder.fetch_new_events
      expect(Member.first).to have_attributes(
        first_name: person_response['person']['first_name'],
        last_name: person_response['person']['last_name'],
        email: person_response['person']['email']
      )
    end

    it 'should fetch the new event rsvps and insert them' do
      IdentityNationBuilder.fetch_new_events
      expect(EventRsvp.count).to eq(2)
    end
  end
end
