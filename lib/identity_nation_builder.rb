require "identity_nation_builder/engine"

module IdentityNationBuilder
  SYSTEM_NAME = 'nation_builder'
  SYNCING = 'members'
  CONTACT_TYPE = {'rsvp' => 'event', 'tag' => 'tag'}
  PULL_JOBS = [[:fetch_new_events, 1.hours], [:fetch_recruiters, 1.hours]]
  MEMBER_RECORD_DATA_TYPE='object'

  def self.push(sync_id, member_ids, external_system_params)
    begin
      members = Member.where(id: member_ids)
      yield members, nil
    rescue => e
      raise e
    end
  end

  def self.push_in_batches(sync_id, members, external_system_params)
    begin
      members.in_batches(of: Settings.nation_builder.push_batch_amount).each_with_index do |batch_members, batch_index|
        external_system_params_hash = JSON.parse(external_system_params)
        sync_type = external_system_params_hash['sync_type']
        site_slug = external_system_params_hash['site_slug']
        rows = ActiveModel::Serializer::CollectionSerializer.new(
          batch_members,
          serializer: NationBuilderMemberSyncPushSerializer
        ).as_json
        IdentityNationBuilder::API.send(sync_type, site_slug, rows, *sync_type_item(external_system_params_hash)) do |write_result_count, member_ids|
          if sync_type === 'tag'
            member_ids.each do |member_id|
              member = Member.find(member_id[:identity_id])
              member.update_external_id(SYSTEM_NAME, member_id[:nationbuilder_id])
            end
          end

          yield batch_index, write_result_count
        end
      end
    rescue => e
      raise e
    end
  end

  def self.sync_type_item(external_system_params_hash)
    case external_system_params_hash['sync_type']
    when 'rsvp'
      [external_system_params_hash['event_id'], external_system_params_hash['mark_as_attended'], external_system_params_hash['recruiter_id']]
    when 'tag'
      [external_system_params_hash['tag']]
    end
  end

  def self.description(sync_type, external_system_params, contact_campaign_name)
    external_system_params_hash = JSON.parse(external_system_params)
    if sync_type === 'push'
      "#{SYSTEM_NAME.titleize} - #{external_system_params_hash['sync_type'].titleize}: ##{sync_type_item(external_system_params_hash)[0]} (#{CONTACT_TYPE[external_system_params_hash['sync_type']]})"
    else
      "#{SYSTEM_NAME.titleize}: #{external_system_params_hash['pull_job']}"
    end
  end

  def self.worker_currently_running?(method_name, sync_id)
    workers = Sidekiq::Workers.new
    workers.each do |_process_id, _thread_id, work|
      args = work["payload"]["args"]
      worker_sync_id = (args.count > 0) ? args[0] : nil
      worker_sync = worker_sync_id ? Sync.find_by(id: worker_sync_id) : nil
      next unless worker_sync
      worker_system = worker_sync.external_system
      worker_method_name = JSON.parse(worker_sync.external_system_params)["pull_job"]
      already_running = (worker_system == SYSTEM_NAME &&
        worker_method_name == method_name &&
        worker_sync_id != sync_id)
      if already_running
        puts ">>> #{SYSTEM_NAME.titleize} #{method_name} skipping as worker already running ..."
        return true
      end
    end
    puts ">>> #{SYSTEM_NAME.titleize} #{method_name} running ..."
    return false
  end

  def self.get_pull_jobs
    defined?(PULL_JOBS) && PULL_JOBS.is_a?(Array) ? PULL_JOBS : []
  end

  def self.get_push_jobs
    defined?(PUSH_JOBS) && PUSH_JOBS.is_a?(Array) ? PUSH_JOBS : []
  end

  def self.pull(sync_id, external_system_params)
    begin
      pull_job = JSON.parse(external_system_params)['pull_job'].to_s
      self.send(pull_job, sync_id) do |records_for_import_count, records_for_import, records_for_import_scope, pull_deferred|
        yield records_for_import_count, records_for_import, records_for_import_scope, pull_deferred
      end
    rescue => e
      raise e
    end
  end

  def self.fetch_new_events(sync_id, over_period_of_time=1.week)
    ## Do not run method if another worker is currently processing this method
    if self.worker_currently_running?(__method__.to_s, sync_id)
      yield 0, {}, {}, true
      return
    end

    starting_from = (DateTime.now() - over_period_of_time)
    updated_events = IdentityNationBuilder::API.sites_events(starting_from)

    started_at = DateTime.now()
    updated_events_ids = updated_events.map { |nb_event| nb_event["id"] }
    updated_events.each_with_index do |nb_event, index|

      event = Event.find_or_initialize_by(
        system: SYSTEM_NAME,
        subsystem: nb_event["site_slug"],
        external_id: nb_event["id"]
      )

      if event.campaign == nil
        event.campaign = Campaign.find(Settings.nation_builder.default_event_campaign_id)
      end

      event.update!(
        name: nb_event['name'],
        start_time: nb_event['start_time'] && DateTime.parse(nb_event['start_time']),
        end_time: nb_event['end_date'] && DateTime.parse(nb_event['end_date']),
        description: nb_event['intro'],
        location: event_address_full(nb_event),
        latitude: nb_event['venue'].try(:[], 'address').try(:[], 'lat'),
        longitude: nb_event['venue'].try(:[], 'address').try(:[], 'lng'),
        max_attendees: nb_event['capacity'],
        approved: nb_event['status'] == 'published',
        invite_only: !nb_event['rsvp_form']['allow_guests'],
        data: nb_event,
        updated_at: Time.now
      )

      fetch_new_event_rsvps(sync_id, event.id)
    end

    # Set data->status to removed for any event not returned by the api
    Event.where(system: SYSTEM_NAME)
         .where('start_time > ?', starting_from)
         .where('updated_at < ?', started_at - 5.seconds)
         .update_all("data = jsonb_set((case when jsonb_typeof(data::jsonb) <> 'object' then '{}' else data end)::jsonb, '{status}', '\"removed\"')")

    execution_time_seconds = ((DateTime.now - started_at) * 24 * 60 * 60).to_i
    yield(
      updated_events.size,
      updated_events_ids,
      {
        scope: 'nation_builder:events:start_time',
        scope_limit: over_period_of_time,
        started_at: started_at,
        completed_at: DateTime.now,
        execution_time_seconds: execution_time_seconds
      },
      false
    )
  end

  def self.fetch_new_event_rsvps(sync_id, event_id)
    event = Event.find(event_id)
    event_rsvps = IdentityNationBuilder::API.all_event_rsvps(event.subsystem, event.external_id)
    event.update!(
      attendees: event_rsvps.count
    )

    event_rsvps.each_with_index do |nb_event_rsvp, index|
      person = IdentityNationBuilder::API.person(nb_event_rsvp['person_id'])
      member = UpsertMember.call(
        {
          firstname: person['first_name'],
          lastname: person['last_name'],
          external_ids: Hash[SYSTEM_NAME, person['id']],
          emails: [{ email: person['email'] }],
          phones: ['mobile', 'phone'].map{|number_type| person[number_type] }.compact.map{|phone| { phone: phone } }
        },
        entry_point: "#{SYSTEM_NAME}:#{__method__.to_s}",
        ignore_name_change: false
      )
      if member
        member.update_external_id(SYSTEM_NAME, person['id'])
        event_rsvp = EventRsvp.find_or_initialize_by(
          event_id: event.id,
          member_id: member.id
        )
        event_rsvp.update!(
          attended: nb_event_rsvp['attended'],
          data: nb_event_rsvp
        )
      end
      if (index + 1) % 50 == 0
        sleep 10
      end
    end
  end

  def self.fetch_recruiters(sync_id)
    if self.worker_currently_running?(__method__.to_s, sync_id)
      yield 0, {}, {}, true
      return
    end

    recruiters = IdentityNationBuilder::API.recruiters
    yield(
      recruiters.size,
      recruiters,
      {},
      false
    )
  end

  def self.event_address_full(nb_event)
    event_location = ""
    return event_location if nb_event['venue'].nil?
    event_location += "#{nb_event['venue']['name']} - " unless nb_event['venue']['name'].blank?
    venue_address = nb_event['venue']['address']
    return event_location if venue_address.nil?
    event_location += "#{venue_address['address1']} " unless venue_address['address1'].blank?
    event_location +="#{venue_address['address2']} " unless venue_address['address2'].blank?
    event_location +="#{venue_address['address3']}, " unless venue_address['address3'].blank?
    event_location +="#{venue_address['city']}, " unless venue_address['city'].blank?
    event_location +="#{venue_address['state']}, " unless venue_address['state'].blank?
    event_location +="#{venue_address['country_code']}" unless venue_address['country_code'].blank?
    event_location
  end
end
