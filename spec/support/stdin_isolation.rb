# frozen_string_literal: true

require "stringio"

# Helpers for specs that exercise interactive prompts. Production code reads
# $stdin and checks $stdin.tty?; these build stand-in readers so a spec
# controls both the answer and the tty-ness.
module StdinHelpers
  def with_stdin(reader)
    original_stdin = $stdin
    $stdin = reader
    yield
  ensure
    $stdin = original_stdin
  end

  # A StringIO serving `input` that claims to be a tty, so tty-gated prompt
  # code takes its interactive branch.
  def tty_reader(input)
    reader = StringIO.new(input)
    reader.define_singleton_method(:tty?) { true }
    reader
  end

  # Runs the block against a fake interactive terminal: stdin serves `input`
  # and claims to be a tty, stderr is captured. Returns the block result and
  # the captured prompt output.
  def with_interactive_stdin(input, &)
    with_stdin_and_captured_stderr(tty_reader(input), &)
  end

  # Runs the block with a stdin that is not a tty (like a pipe), capturing
  # stderr. Returns the block result and the captured output.
  def with_noninteractive_stdin(&)
    with_stdin_and_captured_stderr(StringIO.new, &)
  end

  def with_stdin_and_captured_stderr(reader, &)
    original_stderr = $stderr
    $stderr = StringIO.new
    result = with_stdin(reader, &)
    [result, $stderr.string]
  ensure
    $stderr = original_stderr
  end
end

RSpec.configure do |config|
  config.include StdinHelpers

  # Every example runs with an empty non-tty stdin, so prompt code can never
  # reach the terminal running the suite: tty-gated paths go non-interactive,
  # and an unexpected read gets EOF instead of blocking on the developer.
  # Specs that want a terminal build one with the helpers above.
  config.around do |example|
    original_stdin = $stdin
    $stdin = StringIO.new
    example.run
  ensure
    $stdin = original_stdin
  end
end
