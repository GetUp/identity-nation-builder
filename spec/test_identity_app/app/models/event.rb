class Event < ApplicationRecord
  has_many :event_rsvps
  has_many :members, through: :event_rsvps

  def set_constituency
    if (nearest_zip = Postcode.nearest_postcode(latitude, longitude))
      constituency = Area.where(area_type: 'pcon_new').where(code: nearest_zip.pcon_new).first
      update!(area_id: constituency.id)
    end
  end
  # after_save :set_constituency, if: ->(obj) { obj.latitude.present? and obj.longitude.present? and obj.area_id.blank? }

  class << self
    def find_near_postcode(postcode, radius)
      if (zip = Postcode.search(postcode))
        return near([zip.latitude, zip.longitude], radius)
      end

      []
    end

    def upsert(payload)
      event = Event.find_by(
        external_id: payload[:event][:external_id],
        technical_type: payload[:event][:technical_type]
      )

      event_payload = payload[:event]

      if event_payload[:host_email]
        member_hash = {
          emails: [{
            email: event_payload[:host_email]
          }]
        }
        member_hash = member_hash.merge(event_payload[:host]) if event_payload[:host]

        host = Member.upsert_member(member_hash)
        event_payload[:host_id] = host.id
      end

      payload_with_valid_attributes = event_payload.select { |x| Event.attribute_names.index(x.to_s) }

      if event
        event.update! payload_with_valid_attributes
      else
        Event.create! payload_with_valid_attributes
      end

      EventRsvp.create_rsvp(payload) if payload[:rsvp]
    end

    def remove_event(payload)
      if (
        event = Event.find_by(
          external_id: payload[:event][:external_id],
          technical_type: payload[:event][:technical_type],
        )
      )
        event.destroy!
      end
    end

    def load_from_csv(row)
      if (
        member = Member.upsert_member(
          { external_ids: { controlshift: row['user_id'] } },
          "event_host:#{row['title']}"
        )
      )
        # create event
        event = Event.find_or_initialize_by(controlshift_event_id: row['id'])
        event.name = row['title']
        event.start_time = row['start']
        event.description = row['description']
        event.host_id = member.id

        # is it linked to a local group?
        unless row['local_chapter_id'].nil?
          event.group_id = row['local_chapter_id']
          if (group = Group.where(controlshift_group_id: row['local_chapter_id']).first)
            group.count_events
          end
        end

        # do we have a location for it?
        if (location = Location.where(controlshift_location_id: row['location_id']).first)
          event.location = location.description
          event.latitude = location.latitude
          event.longitude = location.longitude
        end

        event.created_at = Time.parse(row['created_at'])
        event.save!
      else
        Rails.logger.info("Failed to import event because host details were incomplete - Event ID [#{row['id']}], Event Title [#{row['title']}]")
      end
    end
  end
end
