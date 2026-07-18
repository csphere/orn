# frozen_string_literal: true

require "open3"

module Orn
  # Runs subprocesses, logging the invocation and exit status to stderr in
  # verbose mode. `output` treats a nonzero exit as a normal result, while
  # `run` and `exec` raise on failure.
  class Cmd
    # The captured result of a subprocess. A nonzero exit is not an error;
    # callers inspect `success?` themselves.
    Result = Data.define(
      :stdout,
      :stderr,
      :status
    ) do
      def success?
        status.zero?
      end
    end

    def initialize(output_mode:)
      @output_mode = output_mode
    end

    # Runs the command and captures its output. A nonzero exit is returned,
    # not raised.
    def output(*command)
      log_invocation(command)
      result = capture(command)
      log_result(result)
      result
    end

    # Runs the command, raising Orn::Error on a nonzero exit.
    def run(*command)
      result = output(*command)
      raise nonzero_exit_error(command, result) unless result.success?

      result
    end

    # Runs the command for its side effects only, raising on failure.
    def exec(*command)
      run(*command)
      nil
    end

    private

    def capture(command)
      stdout, stderr, process_status = Open3.capture3(*command)
      Result.new(
        stdout:,
        stderr:,
        status: process_status.exitstatus || 1
      )
    rescue Errno::ENOENT
      raise Orn::Error, "Failed to run #{command.first}: command not found"
    end

    def nonzero_exit_error(command, result)
      program = command.first
      stderr = result.stderr.strip
      return Orn::Error.new("#{program} failed (exit #{result.status})") if stderr.empty?

      Orn::Error.new("#{program} failed: #{stderr}")
    end

    def log_invocation(command)
      return unless @output_mode.verbose

      program, *arguments = command
      warn "[cmd] #{program} #{arguments.join(" ")}"
    end

    def log_result(result)
      return unless @output_mode.verbose

      if result.success?
        warn "[ok]  exit #{result.status}"
      else
        result.stderr.strip.each_line { |line| warn "[err] #{line.chomp}" }
        warn "[err] exit #{result.status}"
      end
    end
  end
end
