# frozen_string_literal: true

# Gates for the DinD system specs (spec/system). These drive the real `orn`
# executable against real git/tmux/docker, so they only run inside the
# system-test container, never against a developer's host environment.
RSpec.configure do |config|
  # `:system` specs need the isolated container (git + tmux). The entrypoint
  # exports ORN_IN_TEST_CONTAINER for the test user.
  config.before(:each, :system) do
    unless ENV["ORN_IN_TEST_CONTAINER"] == "1"
      skip "system specs run inside the DinD container (see `just system-test`)"
    end
  end

  # `:sbx_system` specs additionally create real sandboxes, which need Docker
  # auth. The entrypoint sets ORN_SYSTEM_TEST only when credentials are present.
  config.before(:each, :sbx_system) do
    skip "sbx system specs need Docker auth (DOCKER_SBX_USERNAME/TOKEN)" unless ENV["ORN_SYSTEM_TEST"] == "1"
  end
end
