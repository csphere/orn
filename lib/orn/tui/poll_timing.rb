# frozen_string_literal: true

module Orn
  module TUI
    # Poll cadence shared by the project and global TUI apps. Relies on the
    # including app's any_agent_working?.
    module PollTiming
      # Fast poll while an agent is working so the spinner animates smoothly.
      def poll_timeout
        any_agent_working? ? FAST_POLL_TIMEOUT : POLL_TIMEOUT
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
