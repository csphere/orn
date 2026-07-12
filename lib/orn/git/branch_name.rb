# frozen_string_literal: true

module Orn
  module Git
    # A git branch name, validated against `git check-ref-format` rules plus
    # the stricter orn rules needed for tmux window targeting.
    class BranchName
      # '.' is valid in a git branch name, but a branch becomes a tmux window
      # name, and tmux target syntax ("session:window.pane") uses '.' to
      # separate the window from a pane index. A dot in the name would make
      # that target ambiguous, so it is rejected here even though git allows
      # it. ':' is rejected for the same targeting reason.
      FORBIDDEN_CHARACTERS = ["~", "^", ":", "?", "*", "[", "\\", "."].freeze

      CONTROL_CHARACTER = /[\x00-\x1f\x7f]/

      # Ordered so the reported reason matches the first rule a name breaks.
      # Each entry pairs a human reason with a predicate on the name.
      VALIDATION_RULES = [
        ["cannot be '@'", ->(name) { name == "@" }],
        ["contains control character", ->(name) { name.match?(CONTROL_CHARACTER) }],
        ["contains space", ->(name) { name.include?(" ") }],
        ["contains '..'", ->(name) { name.include?("..") }],
        ["contains '//'", ->(name) { name.include?("//") }],
        ["contains '@{'", ->(name) { name.include?("@{") }],
        ["cannot start with '/'", ->(name) { name.start_with?("/") }],
        ["cannot end with '/'", ->(name) { name.end_with?("/") }],
        ["cannot end with '.lock'", ->(name) { name.split("/").last.to_s.downcase.end_with?(".lock") }],
        ["cannot end with '.'", ->(name) { name.end_with?(".") }],
        ["component cannot start with '.'", ->(name) { name.split("/").any? { |part| part.start_with?(".") } }]
      ].freeze

      def initialize(value)
        @value = value
      end

      # Returns the branch name when valid; raises Orn::Error naming the
      # offending rule otherwise.
      def validate!
        raise Orn::Error, "Invalid branch name: cannot be empty" if @value.empty?

        reason = first_violation
        raise Orn::Error, "Invalid branch name '#{@value}': #{reason}" if reason

        @value
      end

      private

      def first_violation
        rule_violation || forbidden_character_violation
      end

      def rule_violation
        VALIDATION_RULES.each do |reason, predicate|
          return reason if predicate.call(@value)
        end
        nil
      end

      def forbidden_character_violation
        character = FORBIDDEN_CHARACTERS.find { |candidate| @value.include?(candidate) }
        return nil unless character

        "contains '#{character}'"
      end
    end
  end
end
