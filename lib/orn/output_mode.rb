# frozen_string_literal: true

module Orn
  # Controls how commands present output. Verbose logs each executed
  # subprocess to stderr; json suppresses human-readable status text so
  # stdout stays machine-parseable for JSON consumers.
  OutputMode = Data.define(:verbose, :json) do
    # The neutral mode: human-readable status on, verbose logging off.
    def self.default
      new(verbose: false, json: false)
    end

    # A mode with all human-readable status output suppressed, for JSON
    # consumers and shell completions.
    def self.quiet
      new(verbose: false, json: true)
    end

    # Builds a mode from a Thor options hash (as passed to a command).
    def self.from_options(options)
      new(verbose: options[:verbose] || false, json: options[:json] || false)
    end

    # Prints a status line to stderr unless in json mode.
    def status(message)
      warn(message) unless json
    end
  end
end
