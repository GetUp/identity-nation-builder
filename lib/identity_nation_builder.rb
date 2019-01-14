require "identity_nation_builder/engine"

module IdentityNationBuilder
  SYSTEM_NAME='nation_builder'
  BATCH_AMOUNT=10
  CONTACT_TYPE={'rsvp' => 'event', 'tag' => 'list'}
  PULL_JOBS=[:fetch_new_events]

  def self.push(sync_id, members, external_system_params)
    begin
      yield members, nil
    rescue => e
      raise e
    end
  end

  def self.push_in_batches(sync_id, members, external_system_params)
    begin
      members.in_batches(of: BATCH_AMOUNT).each_with_index do |batch_members, batch_index|
        external_system_params_hash = JSON.parse(external_system_params)
        sync_type = external_system_params_hash['sync_type']
        site_slug = external_system_params_hash['site_slug']
        rows = ActiveModel::Serializer::CollectionSerializer.new(
          batch_members,
          serializer: NationBuilderMemberSyncPushSerializer
        ).as_json
        write_result_count = IdentityNationBuilder::API.send(sync_type, site_slug, rows, sync_type_item(external_system_params_hash))

        yield batch_index, write_result_count
      end
    rescue => e
      raise e
    end
  end

  def self.sync_type_item(external_system_params_hash)
    case external_system_params_hash['sync_type']
    when 'rsvp'
      external_system_params_hash['event_id']
    when 'tag'
      external_system_params_hash['tag']
    end
  end

  def self.description(external_system_params, contact_campaign_name)
    external_system_params_hash = JSON.parse(external_system_params)
    "#{SYSTEM_NAME.titleize} - #{external_system_params_hash['sync_type'].titleize}: ##{sync_type_item(external_system_params_hash)} (#{CONTACT_TYPE[external_system_params_hash['sync_type']]})"
  end

  def self.fetch_new_events(force: false)
    starting_from = (DateTime.now() - 3.months)
    updated_events = IdentityNationBuilder::API.sites_events(starting_from)

    updated_events.each do |nb_event|

      event = Event.find_or_initialize_by(
        external_source: SYSTEM_NAME,
        external_subsource: nb_event["site_slug"],
        external_id: nb_event["id"]
      )

      event_rsvps = IdentityNationBuilder::API.all_event_rsvps(event.external_subsource, event.external_id)

      event_location = "#{nb_event['venue']['name']} - #{nb_event['venue']['address']['address1']} #{nb_event['venue']['address']['address2']} #{nb_event['venue']['address']['address3']}, #{nb_event['venue']['address']['city']}, #{nb_event['venue']['address']['state']}, #{nb_event['venue']['address']['country_code']}"
      event.update_attributes!(
        name: nb_event['name'],
        start_time: DateTime.parse(nb_event['start_time']),
        end_time: DateTime.parse(nb_event['end_time']),
        description: nb_event['intro'],
        location: event_location,
        latitude: nb_event['venue']['address']['lat'],
        longitude: nb_event['venue']['address']['lng'],
        attendees: event_rsvps.count,
        max_attendees: nb_event['capacity'],
        approved: nb_event['status'] == 'published',
        invite_only: !nb_event['rsvp_form']['allow_guests']
      )

      event_rsvps.each do |nb_event_rsvp|
        person = IdentityNationBuilder::API.person(nb_event_rsvp['person_id'])

        if member_external_id = MemberExternalId.where(system: SYSTEM_NAME, external_id: person['id']).first
          member = Member.find(member_external_id.member_id)
        else
          member = Member.upsert_member(firstname: person['first_name'], lastname: person['last_name'], emails: [{ email: person['email'] }])
          member_external_id = MemberExternalId.find_or_create_by!(member_id: member.id, external_id: person['id'], system: SYSTEM_NAME)
        end

        event_rsvp = EventRsvp.find_or_initialize_by(
          event_id: event.id,
          member_id: member.id
        )
        event_rsvp.update_attributes!(
          attended: nb_event_rsvp['attended']
        )
      end
    end

    updated_events.size
  end
end
