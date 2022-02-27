# Ensure locale is passed to sidekiq workers
require 'sidekiq/middleware/i18n'

Sidekiq::Extensions.enable_delay!

Sidekiq.configure_server do |config|
  config.redis = {
    url: Settings.sidekiq_redis_url,
    size: Settings.sidekiq_redis_pool_size
  }
end

Sidekiq.configure_client do |config|
  config.redis = {
    url: Settings.sidekiq_redis_url,
    size: Settings.sidekiq_redis_pool_size
  }
end
