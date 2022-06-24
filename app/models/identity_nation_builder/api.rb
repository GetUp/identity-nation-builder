require 'nationbuilder'

module IdentityNationBuilder
  class API
    def self.to_slug(name)
      slug = name.parameterize(separator: "_")
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

    def self.person_upsert(id_member)
      id_data = PersonSerializer.new(id_member)
      nb_id = id_member.member_external_ids.with_system(SYSTEM_NAME).first&.external_id
      person_data = nil

      if nb_id != nil
        # Member has an NB id already, so just fetch that.
        #
        # XXX what about multiple NB ids?
        #
        # Id external ids are strings, the NB API returns ints though, so
        # keep the id consistent with NB.
        nb_id = Integer(nb_id)
        person_data = api(:people, :show, { id: nb_id })['person']
      else
        # Don't know the member's NB id, so need to try to find
        # them. Search by email first since that's the best indicator
        # to match data on, then try the phones

        response = {}

        if id_member.email.present?
          response = api(:people, :match, { email: id_member.email })
        end

        if !response.has_key?('person') && id_data.mobile.present?
          response = api(:people, :match, { mobile: id_data[:mobile] })
        end

        if !response.has_key?('person') && id_data.phone.present?
          response = api(:people, :match, { phone: id_data[:phone] })
        end

        if response.has_key?('person')
          person_data = response['person']
          nb_id = person_data['id']
        end
      end

      if person_data
        # Have or found a NB person that is associated with the Id
        # member.
        #
        # If there is no NB external system id already present on the
        # Id member, assume the two records have not been synchronised
        # before, and perform a full merge. That is, if both records
        # have a different value, use the most recently updated
        # record's value, but if one record does not have a value and
        # the other does, always use that value (disregarding which
        # was most recently updated), so no data is lost.
        #
        # If there is a NB external system id present, assume the two
        # have been merged merged already and always use the more
        # recent values for each attribute.
        #
        # Finally, only do this work if the data does not match, to
        # avoid uncessary work and help acheive a steady state
        if id_data != person_data
          upsert_type = :overwrite

          if !id_member.member_external_ids.with_system(SYSTEM_NAME).first.present?
            upsert_type = :merge
            # set the external id here so UpsertService can find the
            # member
            id_member.update_external_id(SYSTEM_NAME, nb_id)
          end

          id_data.upsert_from_person(person_data, upsert_type)

          if id_data != person_data
            # Id and NB person data still doesn't match, so
            # some more recent updates. Push these to NB.
            api(:people, :update, { id: nb_id, person: id_data.as_json } )['person']['id']
          end
        end
      else
        # Don't have an NB id and couldn't find one, so create them in NB
        nb_id = api(:people, :create, { person: id_data })['person']['id']
        id_member.update_external_id(SYSTEM_NAME, nb_id)
      end

      nb_id
    end

    def self.rsvp_person(site_slug, event_id, person_id, attended=false, recruiter_id=nil)
      rsvp_data = { person_id: person_id }
      rsvp_data[:attended] = true if attended
      rsvp_data[:recruiter_id] = recruiter_id if recruiter_id
      api(:events, :rsvp_create, { id: event_id, site_slug: site_slug, rsvp: rsvp_data })
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

    def self.list_find(name)
      id = nil
      api(:lists, :index, { per_page: 100 })['results'].each do |result|
        if result['name'] == name
          id = result['id']
          break
        end
      end
      raise RuntimeError, 'no such list with slug: #{slug}' unless id
      id
    end

    def self.list_create(name)
      slug = to_slug(name)
      api(:lists, :create,
          { list: {
              name: name,
              slug: slug,
              author_id: Settings.nation_builder.author_id
            }
          }
         )['list_resource']['id']
    end

    def self.list_add_people(list_id, member_ids)
      api(:lists, :add_people, { list_id: list_id, people_ids: member_ids })['id']
    end

    def self.recruiters
      recruiters = api(:people_tags, :people, { tag: 'recruiter' })['results'].map{|org|
        [ org['last_name'], org['id'] ]
      }.sort
      Sidekiq.redis { |r| r.set 'nationbuilder:recruiters', recruiters.to_json}
      recruiters
    end

    def self.cached_recruiters
      list_from_cache('nationbuilder:recruiters')
    end

    private

    def self.is_mobile?(phone)
      mobile_prefix = Settings.options.default_mobile_phone_national_destination_code.to_s
      mobile_prefix && phone =~ /^#{mobile_prefix}/
    end

    def self.api(endpoint, method, params)
      started_at = DateTime.now
      begin
        response = get_api_client.call(endpoint, method, params)

        if not response
          raise NationBuilder::RateLimitedError,
                'Empty response returned from NB API - likely due to Rate Limiting'
        end
      rescue NationBuilder::RateLimitedError => e
        Rails.logger.error('nation_builder.api') { e }
        raise e
      rescue NationBuilder::ClientError => e
        response = JSON.parse(e.message)
        unless response_has_a_no_match_code?(response) ||
               attempt_to_rsvp_person_twice(method, e.message)
          Rails.logger.error('nation_builder.api') { e }
          raise e
        end
      ensure
        log_api_call(started_at, endpoint, method, params, response)
      end

      response
    end

    def self.get_api_client
      NationBuilder::Client.new Settings.nation_builder.site, Settings.nation_builder.token, retries: 8
    end

    def self.response_has_a_no_match_code?(response)
      response && response['code'] == 'no_matches'
    end

    def self.attempt_to_rsvp_person_twice(api_call, error)
      api_call == :rsvp_create && error.include?("signup_id has already been taken")
    end

    def self.log_api_call(started_at, endpoint, method, params, response)
      if Settings.nation_builder.debug
        data = {
          started_at: started_at,
          endpoint: endpoint,
          method: method,
          params: params,
          response: response,
          completed_at: DateTime.now,
        }
        puts "NationBuilder API: #{data.inspect}"
      end
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
