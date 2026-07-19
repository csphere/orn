# frozen_string_literal: true

# Scripted stand-in for Orn::Cmd's subprocess backend. Responses are keyed by
# exact argv. Every invocation is recorded for assertions, and an unscripted
# argv raises so a spec fails loudly instead of passing on a default result.
class FakeCmdBackend
  class UnscriptedCommand < StandardError
  end

  attr_reader :invocations

  def initialize
    @responses = {}
    @invocations = []
  end

  def script(argv, stdout: "", stderr: "", status: 0)
    @responses[argv] = Orn::Cmd::Result.new(
      stdout: stdout,
      stderr: stderr,
      status: status
    )
  end

  # Scripts a missing binary: `capture` raises Errno::ENOENT for this argv,
  # like Open3 does when the command is not installed, so Cmd's
  # command-not-found mapping runs for real.
  def script_missing(argv)
    @responses[argv] = :missing
  end

  # Spawn options (env, chdir) are accepted to match the real backend's
  # interface but ignored: scripts key on argv alone.
  def capture(command, **_options)
    @invocations << command
    response = @responses[command]
    raise UnscriptedCommand, "unscripted command: #{command.join(" ")}" if response.nil?
    raise Errno::ENOENT, command.first if response == :missing

    response
  end
end

# Backend that refuses to run anything. Installed as the default per example,
# so a spec that reaches Orn::Cmd without opting in fails loudly instead of
# silently spawning a real subprocess on the machine running the suite.
class DenyCmdBackend
  def capture(command, **_options)
    raise "example spawned a real subprocess: #{command.join(" ")}\n" \
      "Script it with with_fake_cmd, or tag the example `real_cmd: true` " \
      "if it intentionally drives real binaries."
  end
end

# Installs a FakeCmdBackend for the duration of the block, yielding it for
# scripting and assertions.
module FakeCmdHelpers
  def with_fake_cmd
    original_backend = Orn::Cmd.backend
    fake = FakeCmdBackend.new
    Orn::Cmd.backend = fake
    yield fake
  ensure
    Orn::Cmd.backend = original_backend
  end
end

RSpec.configure do |config|
  config.include FakeCmdHelpers

  # Each example starts with the deny backend unless it opts into real
  # subprocesses (`real_cmd: true`, or the container-gated system specs).
  # Restoring afterwards also means a leaked fake cannot poison later
  # examples regardless of how the example used the seam.
  config.around do |example|
    original_backend = Orn::Cmd.backend
    real_allowed = example.metadata[:real_cmd] ||
                   example.metadata[:system] ||
                   example.metadata[:sbx_system]
    Orn::Cmd.backend = DenyCmdBackend.new unless real_allowed
    example.run
  ensure
    Orn::Cmd.backend = original_backend
  end
end
