require 'nationbuilder'

module IdentityNationBuilder
  class API
    def self.rsvp(site_slug, members, event_id, mark_as_attended=false, recruiter_id=nil)
      member_ids = members.map do |member|
        member = member.except(:id, :nationbuilder_id)
        person = find_or_create_person(member)
        response = rsvp_person(site_slug, event_id, person, mark_as_attended, recruiter_id)
        if person && !response.try(:[], 'rsvp') && mark_as_attended
          pager = NationBuilder::Paginator.new(get_api_client, event_rsvps(site_slug, event_id))
          rsvp = pager.body['results'].select { |result| result['person_id'] == person['id'] }.first
          if rsvp && !rsvp['attended']
            update_rsvp(site_slug, rsvp, mark_as_attended)
          end
        end
      end
      yield member_ids.length, member_ids
    end

    def self.tag(site_slug, members, tag)
      list_id = create_list(tag)['id']
      member_ids = members.map do |member|
        identity_id = member[:id]
        member = member.except(:id, :nationbuilder_id)
        { identity_id: identity_id, nationbuilder_id: find_or_create_person(member)['id'] }
      end
      nationbuilder_ids = member_ids.map { |member| member[:nationbuilder_id] }
      add_people_list(list_id, nationbuilder_ids)
      tag_list(list_id, tag)
      yield member_ids.length, member_ids
    end

    def self.mark_as_attended_to_all_events_on_date(site_slug, members)
      marked_records = 0
      member_ids = members.map { |member| member[:id] }
      rsvps_on_date = EventRsvp.where(member_id: member_ids)
                                .joins(:event)
                                .where('events.start_time::date = ?', Date.current)
                                .where(attended: false)
      rsvps_on_date.each do |rsvp|
        begin
          update_rsvp(rsvp.event.data['site_slug'], rsvp.data, true)
          marked_records += 1
        rescue NationBuilder::ClientError => response
          raise unless response.message =~ /Record not found/i
        end
      end
      yield marked_records, member_ids
    end

    def self.sites
      api(:sites, :index, { per_page: 100 })['results']
    end

    def self.cached_sites
      list_from_cache('nationbuilder:sites')
    end

    def self.sites_events(starting=DateTime.now())
      fetched_sites = sites
      Sidekiq.redis { |r| r.set 'nationbuilder:sites', fetched_sites.to_json}
      site_slugs = fetched_sites.map { |site| site['slug'] }
      fetched_events = all_events(site_slugs, starting)
      Sidekiq.redis { |r| r.set 'nationbuilder:sites_events', fetched_events.to_json}
      fetched_events
    end

    def self.cached_sites_events
      list_from_cache('nationbuilder:sites_events')
    end

    def self.all_events(site_slugs, starting)
      event_results = []
      site_slugs.each do |site_slug|
        page = NationBuilder::Paginator.new(get_api_client, events(site_slug, starting))
        page_results = page.body['results'].map { |result| result['site_slug'] = site_slug; result }
        event_results = event_results + page_results
        loop do
          break unless page.next?
          page = page.next
          page_results = page.body['results'].map { |result| result['site_slug'] = site_slug; result }
          event_results = event_results + page_results
        end
      end
      event_results
    end

    def self.events(site_slug, starting)
      api(:events, :index, { site_slug: site_slug, starting: starting.strftime("%F"), per_page: 100 })
    end

    def self.all_event_rsvps(site_slug, event_id)
      event_rsvp_results = []
      page = NationBuilder::Paginator.new(get_api_client, event_rsvps(site_slug, event_id))
      page_results = page.body['results']
      event_rsvp_results = event_rsvp_results + page_results
      loop do
        break unless page.next?
        page = page.next
        page_results = page.body['results']
        event_rsvp_results = event_rsvp_results + page_results
      end
      event_rsvp_results
    end

    def self.event_rsvps(site_slug, event_id)
      api(:events, :rsvps, { site_slug: site_slug, id: event_id, per_page: 100 })
    end

    def self.find_or_create_person(member)
      person = find_person_by_mobile_or_phone(member)
      person ? person : upsert_person(member)
    end

    def self.rsvp_person(site_slug, event_id, person, attended=false, recruiter_id=nil)
      rsvp_data = { person_id: person['id'] }
      rsvp_data[:attended] = true if attended
      rsvp_data[:recruiter_id] = recruiter_id if recruiter_id
      api(:events, :rsvp_create, { id: event_id, site_slug: site_slug, rsvp: rsvp_data })
    end

    def self.update_rsvp(site_slug, rsvp, mark_as_attended)
      api(:events, :rsvp_update, {
        rsvp_id: rsvp['id'],
        event_id: rsvp['event_id'],
        site_slug: site_slug,
        rsvp: { attended: mark_as_attended, person_id: rsvp['person_id'] }
      })
    end

    def self.person(people_id)
      api(:people, :show, { id: people_id })["person"]
    end

    def self.all_lists
      list_results = []
      page = NationBuilder::Paginator.new(get_api_client, lists)
      page_results = page.body['results']
      list_results = list_results + page_results
      loop do
        break unless page.next?
        page = page.next
        page_results = page.body['results']
        list_results = list_results + page_results
      end
      list_results
    end

    def self.lists
      api(:lists, :index, { per_page: 100 })
    end

    def self.create_list(tag)
      slug = "tempid_#{SecureRandom.hex(11)}"
      name = "Temp list for tag - #{tag}"
      api(:lists, :create, { list: { name: name, slug: slug, author_id: Settings.nation_builder.author_id } })['list_resource']
    end

    def self.add_people_list(list_id, member_ids)
      api(:lists, :add_people, { list_id: list_id, people_ids: member_ids })
    end

    def self.tag_list(list_id, tag)
      api(:lists, :add_tag, { list_id: list_id, tag: URI.escape(tag) })
    end

    def self.recruiters
      recruiters = api(:people_tags, :people, { tag: 'recruiter' })['results'].map{|org|
        [ org['last_name'], org['id'] ]
      }.sort
      recruiters
    end

    def self.cached_recruiters
      list_from_cache('nationbuilder:recruiters')
    end

    private

    def self.find_person_by_mobile_or_phone(member)
      phone_to_lookup = member[:mobile].present? ? member[:mobile] : member[:phone]
      if phone_to_lookup.present?
        phone_to_lookup = strip_leading_zero(phone_to_lookup)
        phone_type = is_mobile?(phone_to_lookup) ? "mobile" : "phone"
        response = api(:people, :match, { phone_type => phone_to_lookup })
        matched_person = response['person']
        return matched_person if matched_person
      end
    end

    def self.strip_leading_zero(phone)
      phone.gsub(/^0/, '')
    end

    def self.is_mobile?(phone)
      mobile_prefix = Settings.options.default_mobile_phone_national_destination_code.to_s
      mobile_prefix && phone =~ /^#{mobile_prefix}/
    end

    def self.upsert_person(member)
      begin
        upsert_person_without_retry(member)
      rescue NationBuilder::ClientError => response
        validation_errors = JSON.parse(response.message)['validation_errors']
        if validation_errors.try(:first).try(:match, /should look like an email address/)
          upsert_person_without_retry(member.except(:email))
        else
          raise response
        end
      end
    end


    def self.upsert_person_without_retry(member)
      api(:people, :add, { person: member })['person']
    end

    def self.api(*args)
      args[2] = {} unless args.third
      args.third[:fire_webhooks] = false
      started_at = DateTime.now
      begin
        payload = get_api_client.call(*args)
        raise_if_empty_payload payload
      rescue NationBuilder::RateLimitedError
        raise
      rescue NationBuilder::ClientError => e
        payload = JSON.parse(e.message)
        unless payload_has_a_no_match_code?(payload) || attempt_to_rsvp_person_twice(args[1], e.message)
          log_api_call(started_at, payload, *args)
          raise
        end
      end
      log_api_call(started_at, payload, *args)
      payload
    end

    def self.get_api_client
      NationBuilder::Client.new Settings.nation_builder.site, Settings.nation_builder.token, retries: 8
    end

    def self.payload_has_a_no_match_code?(payload)
      payload && payload['code'] == 'no_matches'
    end

    def self.attempt_to_rsvp_person_twice(api_call, error)
      api_call == :rsvp_create && error.include?("signup_id has already been taken")
    end

    def self.raise_if_empty_payload(payload)
      raise RuntimeError, 'Empty payload returned from NB API - likely due to Rate Limiting' if payload.nil?
    end

    def self.log_api_call(started_at, payload, *call_args)
      return unless Settings.nation_builder.debug
      data = {
        started_at: started_at, payload: payload, completed_at: DateTime.now,
        endpoint: call_args[0..1].join('/'), data: call_args.third,
      }
      puts "NationBuilder API: #{data.inspect}"
    end

    def self.list_from_cache(cache_key)
      if json = Sidekiq.redis { |r| r.get cache_key }
        JSON.parse(json)
      else
        []
      end
    end
  end
end
