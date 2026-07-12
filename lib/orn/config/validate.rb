# frozen_string_literal: true

module Orn
  module Config
    # Validation for user-supplied config values: session names, sandbox
    # names, and port ranges. Each method raises Orn::Error on an invalid
    # value and returns nil otherwise.
    module Validate
      SANDBOX_NAME_CHARACTER = /[a-zA-Z0-9.-]/
      SESSION_NAME_CHARACTER = %r{[a-zA-Z0-9_/-]}
      ALPHANUMERIC = /[a-zA-Z0-9]/

      # sbx naming rules: at least 2 characters of [a-zA-Z0-9.-], starting
      # with a letter or digit and not ending with a hyphen.
      def self.sandbox_name!(name)
        raise Orn::Error, "sandbox name must be at least 2 characters" if name.length < 2

        invalid = name.chars.find { |character| !character.match?(SANDBOX_NAME_CHARACTER) }
        if invalid
          raise Orn::Error,
            "sandbox name contains invalid character '#{invalid}': only [a-zA-Z0-9.-] are allowed"
        end

        raise Orn::Error, "sandbox name must start with a letter or digit" unless name[0].match?(ALPHANUMERIC)
        raise Orn::Error, "sandbox name must not end with a hyphen" if name.end_with?("-")

        nil
      end

      # Rejects session names that are empty or contain characters outside
      # [a-zA-Z0-9/_-]; characters like ':' and '.' have meaning in tmux
      # targets and could address other sessions.
      def self.session_name!(name)
        raise Orn::Error, "session name must not be empty" if name.empty?

        invalid = name.chars.find { |character| !character.match?(SESSION_NAME_CHARACTER) }
        return nil unless invalid

        raise Orn::Error,
          "session name contains invalid character '#{invalid}': only [a-zA-Z0-9/_-] are allowed"
      end

      # Requires both ports non-zero and start <= end.
      def self.host_range!(range)
        start_port, end_port = range
        if start_port.zero? || end_port.zero?
          raise Orn::Error, "host_range ports must be greater than 0, got [#{start_port}, #{end_port}]"
        end
        return nil unless start_port > end_port

        raise Orn::Error, "host_range start (#{start_port}) must not exceed end (#{end_port})"
      end
    end
  end
end
