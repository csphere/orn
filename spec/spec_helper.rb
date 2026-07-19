# frozen_string_literal: true

# Coverage is opt-in because it slows the suite: run `COVERAGE=1 bundle exec
# rspec`. SimpleCov must start before the code under test is required.
if ENV["COVERAGE"]
  require "simplecov"
  # The test container mounts the source read-only and provides a writable
  # /coverage mount for the report instead.
  SimpleCov.coverage_dir(ENV["ORN_COVERAGE_DIR"]) if ENV["ORN_COVERAGE_DIR"]
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
  # Enable flags like --only-failures and --next-failure. The test container
  # mounts the source read-only and points this at a path under /tmp.
  config.example_status_persistence_file_path = ENV.fetch("ORN_RSPEC_STATUS_FILE", ".rspec_status")

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
