# frozen_string_literal: true

module Orn
  module Git
    # Runs git against one directory: every call goes through Orn::Cmd as
    # `git -C <dir> ...`, so verbose logging, ENOENT mapping, and the
    # nonzero-exit policy stay in one place. `output` returns failures,
    # `run`/`exec` raise, and `ok?`/`read` collapse the
    # success-check-plus-rescue idiom callers used to hand-write.
    class Repo
      attr_reader :dir

      # `env` adds environment variables for every spawned git process.
      def initialize(dir:, output_mode:, env: nil)
        @dir = dir.to_s
        @cmd = Orn::Cmd.new(
          output_mode: output_mode,
          env: env
        )
      end

      # Captures output; a nonzero exit is returned, not raised.
      def output(*args)
        @cmd.output(
          "git",
          "-C",
          @dir,
          *args
        )
      end

      # Runs the command, raising Orn::Error on a nonzero exit.
      def run(*args)
        @cmd.run(
          "git",
          "-C",
          @dir,
          *args
        )
      end

      # Side effects only, raising on failure.
      def exec(*args)
        run(*args)
        nil
      end

      # Advisory: true only when git ran and exited zero. A failed spawn
      # (missing git) counts as false, not an exception.
      def ok?(*args)
        output(*args).success?
      rescue Orn::Error
        false
      end

      # Stdout on success; nil on a nonzero exit or a failed spawn.
      def read(*args)
        result = output(*args)
        return nil unless result.success?

        result.stdout
      rescue Orn::Error
        nil
      end
    end
  end
end
