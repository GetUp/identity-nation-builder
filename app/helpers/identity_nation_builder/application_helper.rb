module IdentityNationBuilder
  module ApplicationHelper
    def self.push_types_for_select
      [
        ["Event RSVP", :rsvp],
        ["Tag", :tag],
      ]
    end

    def self.events_for_select
      IdentityNationBuilder::API.cached_sites_events.map { |x| ["##{x['id']}: #{x['title']} - #{x['start_time'].to_time.strftime('%a %d %b %Y %l:%M%p')} (timezone: #{x['time_zone']})", x['id'], {class: "site_slug_#{x['site_slug']}"}] }
    end

    def self.sites_for_select
      IdentityNationBuilder::API.cached_sites.map { |x| ["#{x['name']}", x['slug']] }
    end

    def self.recruiters
      IdentityNationBuilder::API.cached_recruiters
    end
  end
end
