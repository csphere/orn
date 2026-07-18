# frozen_string_literal: true

require "tmpdir"

# Helpers for specs that drive a real tmux server.
module TmuxSpecSupport
  # Whether a tmux binary is on PATH; specs gate their integration examples on
  # this so the suite still passes on a host without tmux.
  AVAILABLE = system(
    "tmux",
    "-V",
    out: File::NULL,
    err: File::NULL
  )
end

# Runs each example against a throwaway private tmux server. Unsetting TMUX
# detaches from any inherited server (otherwise tmux targets $TMUX and ignores
# TMUX_TMPDIR), and TMUX_TMPDIR points the new server's socket at a scratch dir.
# This guarantees the real user server is never touched, so the kill-server
# cleanup can only reap our private one.
RSpec.shared_context "with an isolated tmux server" do
  around do |example|
    original_tmux = ENV.fetch("TMUX", nil)
    original_tmpdir = ENV.fetch("TMUX_TMPDIR", nil)
    Dir.mktmpdir do |socket_dir|
      ENV.delete("TMUX")
      ENV["TMUX_TMPDIR"] = socket_dir
      example.run
    ensure
      if ENV["TMUX_TMPDIR"] == socket_dir
        system(
          "tmux",
          "kill-server",
          out: File::NULL,
          err: File::NULL
        )
      end
      ENV["TMUX"] = original_tmux
      ENV["TMUX_TMPDIR"] = original_tmpdir
    end
  end
end
