# frozen_string_literal: true

module Orn
  # Base class for all orn errors. The entry point rescues this and exits
  # nonzero, printing the message to stderr.
  class Error < StandardError; end
end
