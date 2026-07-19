# frozen_string_literal: true

require "tmpdir"

# Snapshots ENV before each example and restores it afterwards, so specs may
# freely set or delete environment variables without leaking across examples.
#
# On top of the snapshot, HOME and the XDG base dirs are pointed at a throwaway
# tmpdir. Code under test that falls back to ~/.config, ~/.local/share, or
# ~/.local/state (config loader, trust approvals, TUI state) writes there
# instead of the developer's real home, and one example's writes cannot leak
# into the next. System specs (:system/:sbx_system) are exempt: they drive the
# real orn executable inside the test container and need the container home's
# git identity and sbx auth.
RSpec.configure do |config|
  config.around do |example|
    original_env = ENV.to_hash
    if example.metadata[:system] || example.metadata[:sbx_system]
      example.run
    else
      Dir.mktmpdir("orn-home") do |home_dir|
        ENV["HOME"] = home_dir
        ENV["XDG_CONFIG_HOME"] = File.join(home_dir, ".config")
        ENV["XDG_DATA_HOME"] = File.join(home_dir, ".local/share")
        ENV["XDG_STATE_HOME"] = File.join(home_dir, ".local/state")
        # A committer identity, so code under test can `git commit` without
        # depending on whatever identity (or OS-level fallback) the machine
        # running the suite happens to have.
        File.write(
          File.join(home_dir, ".gitconfig"),
          "[user]\n\tname = Orn Test\n\temail = test@orn.invalid\n"
        )
        example.run
      end
    end
  ensure
    ENV.replace(original_env)
  end
end
