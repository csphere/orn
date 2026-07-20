# frozen_string_literal: true

module Orn
  # The monotonic clock used for every elapsed-time measurement (TUI poll
  # cadences, port verification backoff).
  module Clock
    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
