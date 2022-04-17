# This patch allows accessing the settings hash with dot notation
class Hash
  def method_missing(method, *opts)
    m = method.to_s
    return self[m] if key?(m)
    super
  end
end

class Settings

  def self.nation_builder
    return {
      "site_slug" => ENV['NATION_BUILDER_SITE_SLUG'],
      "site" => ENV['NATION_BUILDER_SITE'],
      "token" => ENV['NATION_BUILDER_TOKEN'],
      "debug" => ENV['NATION_BUILDER_DEBUG'],
      "author_id" => ENV['NATION_BUILDER_AUTHOR_ID'],
      "default_event_campaign_id" => ENV['NATION_BUILDER_DEFAULT_EVENT_CAMPAIGN_ID'].to_i,
      "push_batch_amount" => ENV['NATION_BUILDER_PULL_BATCH_AMOUNT'].to_i,
      "pull_batch_amount" => ENV['NATION_BUILDER_PUSH_BATCH_AMOUNT'].to_i,
    }
  end

  def self.app
    return {
      "inbound_url" => 'https://example.com/inbound'
    }
  end

  def self.options
    return {
      "ignore_name_change_for_donation" => true
    }
  end

  def self.databases
    return { }
  end

  def self.sidekiq_redis_url
    return ENV['SIDEKIQ_REDIS_URL']
  end

  def self.sidekiq_redis_pool_size
    return ENV['SIDEKIQ_REDIS_POOL_SIZE'] || 12
  end

end
