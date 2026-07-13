# frozen_string_literal: true

require "rbconfig"

module Orn
  module Detect
    # Platform-specific discovery of the foreground process group on a pane's
    # controlling terminal. Linux reads `/proc`; macOS shells out to `ps`.
    # Unsupported platforms return nil, skipping wrapped-agent detection.
    module Platform
      def self.foreground_job(child_pid)
        case host_os
        when :linux then Linux.foreground_job(child_pid)
        when :macos then Macos.foreground_job(child_pid)
        end
      end

      def self.host_os
        os = RbConfig::CONFIG["host_os"]
        return :macos if os.include?("darwin")
        return :linux if os.include?("linux")

        :other
      end
    end
  end
end
