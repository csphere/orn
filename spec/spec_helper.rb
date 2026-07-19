# frozen_string_literal: true

# Coverage is opt-in because it slows the suite: run `COVERAGE=1 bundle exec
# rspec`. SimpleCov must start before the code under test is required.
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
  end
end

require "orn"

Dir[File.join(
  __dir__,
  "support",
  "**",
  "*.rb"
)].each { |file| require file }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
