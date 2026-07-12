# frozen_string_literal: true

# Snapshots ENV before each example and restores it afterwards, so specs may
# freely set or delete environment variables without leaking across examples.
RSpec.configure do |config|
  config.around do |example|
    original_env = ENV.to_hash
    example.run
  ensure
    ENV.replace(original_env)
  end
end
