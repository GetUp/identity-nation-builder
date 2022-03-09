# == Schema Information
#
# Table name: campaigns
#
#  id                       :integer          not null, primary key
#  name                     :text
#  created_at               :datetime
#  updated_at               :datetime
#  issue_id                 :integer
#  description              :text
#  author_id                :integer
#  controlshift_campaign_id :integer
#  campaign_type            :text
#  languages                :string           array: true
#  latitude                 :float
#  longitude                :float
#  location                 :text
#  image                    :text
#  url                      :text
#  slug                     :text
#  won                      :boolean
#

class Campaign < ApplicationRecord
  has_many :actions
  belongs_to :issue, optional: true
  belongs_to :author, class_name: 'Member', optional: true

  scope :unfinished, -> {
    where(finished_at: nil)
  }

  scope :finished, -> {
    where.not(finished_at: nil)
  }

  scope :recently_finished, -> {
    where("finished_at > ?", 1.year.ago)
  }

  scope :controlshift, -> {
    where(campaign_type: 'controlshift')
  }
  scope :not_controlshift, -> {
    where.not(id: controlshift)
  }

  scope :unfinished_or_recently_finished, -> {
    self.unfinished.or(self.recently_finished)
  }

  def store_action_language(language)
    unless languages.include?(language)
      languages.push(language)
      save!
    end
  end

  def self.load_from_csv(row)
    campaign = Campaign.find_or_initialize_by(controlshift_campaign_id: row['id'])

    # upsert campaign
    campaign.name = row['title'].to_s
    campaign.description = row['what'].to_s
    campaign.campaign_type = 'controlshift'
    campaign.image = row['image_file_name'].to_s
    campaign.latitude = row['location_latitude'].to_f
    campaign.longitude = row['location_longitude'].to_f
    campaign.location = row['location_locality'].to_s
    campaign.slug = row['slug'].to_s
    campaign.moderation_status = row['admin_status'].to_s

    if row['ended_type'].present? && campaign.outcome != row['ended_type'].to_s
      campaign.finished_at = row['updated_at'].to_s
      campaign.outcome = row['ended_type'].to_s
    end

    if row['created_at_date']
      campaign.created_at = Date.strptime(row['created_at_date'], '%m/%d/%Y')
    end

    if (issue_link = ControlshiftIssueLink.find_by(controlshift_tag: (row['categories'] || '').split(',').first))
      campaign.issue_id = issue_link.issue_id
    end

    campaign.save!

    # If the petition isn't launched, the petition starter hasn't finished creating the petition yet, so no-one can see
    # or sign the petition, and the petition starter may not have filled out their email address yet!
    # Ideally we would ignore petitions until they're launched, but the Controlshift CSV data load only sends petition
    # data when the row is 1st created, and during the nightly full data load. So this would mean not recording any
    # signatures for a petition in ID until we get the CSV confirming it has been laucnhed, which will only happen
    # overnight. Could this be improved by using Controlshift webhooks (there's a petition.launched hook)?
    if row['launched'].in?(['true', 't'])
      ControlshiftGetPetitionAuthorWorker.perform_async(campaign.id)
    end

    # add group campaign if it's linked to a group
    if row['group_id'].present?
      GroupCampaign.find_or_create_by!(
        group: Group.find_or_create_by!(controlshift_group_id: row['group_id']),
        campaign_id: campaign.id,
      )
    end
  end

  class << self
    def trending_petitions(count = 10, hours = 24)
      hours = ApplicationRecord.connection.quote(hours)
      count = ApplicationRecord.connection.quote(count)
      sql = <<~SQL
          SELECT a.id, a.public_name, a.campaign_id, a.external_id, a.technical_type,
                 c.slug, count(distinct ma.member_id) as participants
            FROM member_actions ma
            JOIN actions a
              ON a.id = ma.action_id
            JOIN campaigns c
              ON c.id = a.campaign_id
           WHERE ma.created_at >= current_timestamp - interval '#{hours} hours'
             AND a.action_type='petition'
        GROUP BY a.id, a.public_name, a.campaign_id, a.external_id, a.technical_type, c.slug
        ORDER BY count(*) desc
           LIMIT #{count}
      SQL
      RedshiftDB.connection.execute(sql)
    end

    def latest_wins(count = 10, days = 365)
      days = ApplicationRecord.connection.quote(days)
      count = ApplicationRecord.connection.quote(count)
      sql = <<~SQL
          SELECT c.id, a.public_name, c.outcome, c.finished_at,
                 count(distinct ma.member_id) as participants
            FROM campaigns c
            JOIN actions a
              ON a.campaign_id = c.id
            JOIN member_actions ma
              ON ma.action_id = a.id
           WHERE c.outcome = 'won'
           AND c.finished_at > current_timestamp - interval '#{days} days'
             AND a.action_type != 'create-petition'
        GROUP BY c.id, a.public_name, c.outcome, c.finished_at
        ORDER BY c.finished_at DESC
           LIMIT #{count}
      SQL
      RedshiftDB.connection.execute(sql)
    end

    def biggest_recent_wins(count = 10, days = 365, minimum_size = 1000)
      days = ApplicationRecord.connection.quote(days)
      count = ApplicationRecord.connection.quote(count)
      minimum_size = ApplicationRecord.connection.quote(minimum_size)
      sql = <<~SQL
        SELECT id, public_name, finished_at, participants FROM (
          SELECT c.id, a.public_name, c.outcome, c.finished_at,
                 count(distinct ma.member_id) as participants
            FROM campaigns c
            JOIN actions a
              ON a.campaign_id = c.id
            JOIN member_actions ma
              ON ma.action_id = a.id
           WHERE c.outcome = 'won'
           AND c.finished_at > current_timestamp - interval '#{days} days'
        GROUP BY c.id, a.public_name, c.outcome, c.finished_at
        ) tmp
        WHERE participants >= #{minimum_size}
        ORDER BY participants DESC
           LIMIT #{count}
      SQL
      RedshiftDB.connection.execute(sql)
    end

    def campaign_url(action)
      # Construct the URL for a campaign
      campaign_url = Settings.app.home_url
      if action['technical_type']&.match(/speakout/)
        campaign_url = "#{Settings.speakout.url}/campaigns/#{action['slug']}"
      elsif action['technical_type'] == 'cby_petition' || action['technical_type'] == 'csl_petition'
        campaign_url = "#{Settings.controlshift_api.url}/petitions/#{action['slug']}"
      end
      campaign_url
    end

    def readable_date(date)
      # Transform date to readable format, e.g. "5th of April"
      dt = DateTime.parse date.to_s
      "#{dt.day.ordinalize} of #{dt.strftime '%B'}"
    end

    def readable_name(name)
      # Strip trailing punctuation that interferes with pacing of verbal output
      name.sub!(/[\.\,\!\?]+$/, '')
      # Change smart/weird quotes into normal quotes
      name.gsub!(/[‘’`´]/, "'")
      name.gsub(/[“”]/, '"')
    end

    def readable_number(number)
      # Round down numbers for easier listening comprehension
      if number > 10_000
        number = number.to_s.sub(/\d\d\d$/, '000')
      elsif number > 1_000
        number = number.to_s.sub(/\d\d$/, '00')
      elsif number > 100
        number = number.to_s.sub(/\d$/, '0')
      end
      number.to_i
    end

    def alexa_flash_briefing
      alexa_items = Array.new
      now = Time.current

      # Build a feed containing today's top 3 petitions
      trending_petitions = trending_petitions(3, 24).to_a
      trending_petitions.each_with_index do |petition, i|
        participants    = readable_number petition['participants'].to_i
        petition_name   = readable_name   petition['public_name']
        redirection_url = campaign_url    petition
        trending_item = {
          uid: "CAMPAIGN_#{petition['campaign_id']}",
          titleText: petition_name,
          mainText: "#{participants} new people have signed #{petition_name}",
          updateDate: (now - i).utc.iso8601, # Alexa uses this timestamp as an 'order by'
          redirectionUrl: redirection_url
        }
        alexa_items.push trending_item
      end

      # Add details of latest campaign win to end of feed
      latest_win = latest_wins(1, 90).first
      if latest_win
        win_id   = latest_win['id']
        win_date = readable_date   latest_win['finished_at']
        win_name = readable_name   latest_win['public_name']
        winners  = readable_number latest_win['participants'].to_i
        win_item = {
          uid: "WIN_#{win_id}",
          titleText: win_name,
          mainText: "Most recent campaign victory: #{win_name} was won on the #{win_date}, by over #{winners} people",
          updateDate: (now - 4).utc.iso8601,
          redirectionUrl: Settings.app.home_url # TODO: blog post?
        }
        alexa_items.push win_item

        # Add details of latest big campaign win to end of feed, if different from above
        big_win = biggest_recent_wins(1, 90, 10000).first
        if big_win && big_win.id.to_i != latest_win.id.to_i
          big_win_id   = big_win['id']
          big_win_date = readable_date   big_win['finished_at']
          big_win_name = readable_name   big_win['public_name']
          big_winners  = readable_number big_win['participants'].to_i
          big_win_item = {
            uid: "BIG_WIN_#{big_win_id}",
            titleText: big_win_name,
            mainText: "Featured campaign victory: #{big_win_name} was won on the #{big_win_date}, by over #{big_winners} people",
            updateDate: (now - 5).utc.iso8601,
            redirectionUrl: Settings.app.home_url # TODO: blog post?
          }
          alexa_items.push big_win_item
        end
      end

      alexa_items
    end
  end
end
