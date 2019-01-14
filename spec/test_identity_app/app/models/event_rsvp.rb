class EventRsvp < ApplicationRecord
  belongs_to :event
  belongs_to :member

  class << self
    def create_rsvp(payload)
      if (
        event = Event.find_by(
          external_id: payload[:event][:external_id],
          technical_type: payload[:event][:technical_type],
        )
      )
        member_hash = {
          emails: [{
            email: payload[:rsvp][:email]
          }],
          firstname: payload[:rsvp][:first_name],
          lastname: payload[:rsvp][:last_name]
        }

        if (member = Member.upsert_member(member_hash))
          EventRsvp.create!(member: member, event: event)
        else
          logger.info "RSVP failed to save because the member for this RSVP doesn't exist and couldn't be created from the payload"
          false
        end
      else
        logger.info "RSVP failed to save because event #{payload[:event].inspect} doesn't exist"
        false
      end
    end

    def remove_rsvp(payload)
      if (
        event = Event.find_by(
          external_id: payload[:event][:external_id],
          technical_type: payload[:event][:technical_type],
        )
      )
        if (member = Member.find_by_email(payload[:rsvp][:email]))
          EventRsvp.find_by(event_id: event.id, member_id: member.id).try(:destroy)
        end
      end
    end

    def load_from_csv(row)
      if (event = Event.find_by(controlshift_event_id: row['event_id']))
        if (member = Member.upsert_member({ emails: [{ email: row['email'] }] }, "event_rsvp"))
          event_rsvp = EventRsvp.find_or_initialize_by({
            event_id: event.id,
            member_id: member.id
          })
          event_rsvp.created_at ||= row['created_at']
          event_rsvp.deleted_at = (row['attending_status'] == 'not_attending' ? row['created_at'] : nil)
          event_rsvp.save!
        else
          logger.info("Couldn't create event RSVP as the member was invalid - row ID #{row['id']}")
        end
      else
        logger.info("Couldn't create event RSVP as we don't have the event yet - event ID #{row['event_id']}")

        # Tomorrow's daily run should pick up this RSVP anyway, and if something
        # is permenantly wrong with loading the event this will cycle forever...
        # EventRsvp.delay_for(5.minutes).load_from_csv(row)
      end
    end
  end
end
