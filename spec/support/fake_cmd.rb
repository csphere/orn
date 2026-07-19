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

  def capture(command)
    @invocations << command
    response = @responses[command]
    raise UnscriptedCommand, "unscripted command: #{command.join(" ")}" if response.nil?

    response
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

  # A leaked fake would poison every later example, so the real backend is
  # restored around each one regardless of how the example used the seam.
  config.around do |example|
    original_backend = Orn::Cmd.backend
    example.run
  ensure
    Orn::Cmd.backend = original_backend
  end
end
