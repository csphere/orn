# frozen_string_literal: true

# Pins the host platform so specs behave the same on Linux and macOS.
# Platform-gated code (colima doctor checks, /proc vs ps agent detection)
# reads RbConfig::CONFIG["host_os"] at call time, so stubbing it steers
# every gate in the example.
module HostOsHelpers
  def stub_host_os(value)
    allow(RbConfig::CONFIG).to receive(:[]).and_call_original
    allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return(value)
  end
end

RSpec.configure do |config|
  config.include HostOsHelpers
end
