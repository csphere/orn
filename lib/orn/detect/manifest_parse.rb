# frozen_string_literal: true

module Orn
  module Detect
    # Parsing and validation of raw manifest hashes into Rule/Gate
    # structures, split out of manifest.rb. Entry point: parse_manifest.
    module Manifest
      def self.parse_manifest(raw)
        raise InvalidManifest, "manifest must be a mapping" unless raw.is_a?(Hash)

        reject_unknown_keys(
          raw,
          MANIFEST_KEYS,
          "manifest"
        )
        id = raw["id"]
        raise InvalidManifest, "manifest id must be a string" unless id.is_a?(String)

        rules_raw = raw["rules"] || []
        raise InvalidManifest, "manifest rules must be a list" unless rules_raw.is_a?(Array)

        manifest = ParsedManifest.new(
          id: id,
          aliases: string_list(raw["aliases"], "aliases"),
          rules: rules_raw.map { |rule| parse_rule(rule) }
        )
        validate_manifest(manifest)
        manifest
      end

      def self.parse_rule(raw)
        raise InvalidManifest, "rule must be a mapping" unless raw.is_a?(Hash)

        reject_unknown_keys(
          raw,
          RULE_KEYS,
          "rule"
        )
        id = raw["id"]
        raise InvalidManifest, "rule id must be a string" unless id.is_a?(String)

        region = raw.fetch("region", DEFAULT_REGION)
        raise InvalidManifest, "rule region must be a string" unless region.is_a?(String)

        Rule.new(
          id: id,
          state: parse_state(raw["state"]),
          priority: parse_int(
            raw["priority"],
            0,
            "priority"
          ),
          region: region,
          gate: gate_from(raw),
          **rule_flags(raw)
        )
      end

      def self.rule_flags(raw)
        {
          visible_idle: parse_bool(raw["visible_idle"], "visible_idle"),
          visible_blocker: parse_bool(raw["visible_blocker"], "visible_blocker"),
          visible_working: parse_bool(raw["visible_working"], "visible_working"),
          skip_state_update: parse_bool(raw["skip_state_update"], "skip_state_update")
        }
      end

      def self.parse_gate(raw)
        raise InvalidManifest, "gate must be a mapping" unless raw.is_a?(Hash)

        reject_unknown_keys(
          raw,
          GATE_KEYS,
          "gate"
        )
        gate_from(raw)
      end

      # Reads the six matcher fields from a rule or gate hash (other keys are
      # already validated by the caller).
      def self.gate_from(raw)
        Gate.new(
          all: gate_list(raw["all"]),
          any: gate_list(raw["any"]),
          not_gate: gate_list(raw["not"]),
          contains: string_list(raw["contains"], "contains"),
          regex: string_list(raw["regex"], "regex"),
          line_regex: string_list(raw["line_regex"], "line_regex")
        )
      end

      def self.gate_list(value)
        return [] if value.nil?
        raise InvalidManifest, "gate list must be a list" unless value.is_a?(Array)

        value.map { |gate| parse_gate(gate) }
      end

      def self.string_list(value, label)
        return [] if value.nil?
        raise InvalidManifest, "#{label} must be a list of strings" unless value.is_a?(Array) && value.all?(String)

        value
      end

      def self.parse_int(value, default, label)
        return default if value.nil?
        raise InvalidManifest, "#{label} must be an integer" unless value.is_a?(Integer)

        value
      end

      def self.parse_bool(value, label)
        return false if value.nil?
        return value if [true, false].include?(value)

        raise InvalidManifest, "#{label} must be a boolean"
      end

      def self.parse_state(value)
        return nil if value.nil?

        state = STATES[value]
        raise InvalidManifest, "invalid state: #{value}" if state.nil?

        state
      end

      def self.reject_unknown_keys(raw, allowed, context)
        unknown = raw.keys - allowed
        raise InvalidManifest, "unknown #{context} field(s): #{unknown.join(", ")}" unless unknown.empty?
      end

      # Enforce structural invariants and complexity caps across all rules.
      def self.validate_manifest(manifest)
        raise InvalidManifest, "manifest must contain at least one rule" if manifest.rules.empty?
        if manifest.rules.length > MAX_RULES_PER_MANIFEST
          raise InvalidManifest, "manifest contains #{manifest.rules.length} rules, max is #{MAX_RULES_PER_MANIFEST}"
        end

        complexity = {
          gates: 0,
          matchers: 0
        }
        manifest.rules.each { |rule| validate_rule(rule, complexity) }
      end

      def self.validate_rule(rule, complexity)
        raise InvalidManifest, "manifest rule id must not be empty" if rule.id.strip.empty?

        validate_skip_state_update(rule)
        validate_region_name(rule.region, rule.id)
        begin
          validate_gate(
            rule.gate,
            "rule",
            0,
            complexity
          )
          compile_gate(rule.gate)
        rescue InvalidManifest => e
          raise InvalidManifest, "rule #{rule.id} has invalid matcher gates: #{e.message}"
        end
      end

      def self.validate_skip_state_update(rule)
        return unless rule.skip_state_update

        unless rule.state == :unknown
          raise InvalidManifest, "rule #{rule.id} uses skip_state_update without state = \"unknown\""
        end
        return unless rule.visible_idle || rule.visible_blocker || rule.visible_working

        raise InvalidManifest, "rule #{rule.id} uses skip_state_update with visible state evidence"
      end

      def self.validate_region_name(spec, rule_id)
        trimmed = spec.strip
        return if REGION_NAMES.include?(trimmed)
        return if region_count(trimmed, "bottom_lines") || region_count(trimmed, "bottom_non_empty_lines")

        raise InvalidManifest, "rule #{rule_id} uses invalid region: #{trimmed}"
      end

      # Validate a gate in positive position: depth/complexity limits plus the
      # requirement of at least one positive matcher (pure-`not` matches too
      # broadly to be intentional).
      def self.validate_gate(gate, context, depth, complexity)
        check_gate_budget(
          gate,
          context,
          depth,
          complexity
        )
        raise InvalidManifest, "#{context} must contain a positive matcher" unless positive_matcher?(gate)

        gate.all.each do |nested|
          validate_gate(
            nested,
            "all gate",
            depth + 1,
            complexity
          )
        end
        gate.any.each do |nested|
          validate_gate(
            nested,
            "any gate",
            depth + 1,
            complexity
          )
        end
        gate.not_gate.each do |nested|
          raise InvalidManifest, "#{context} contains an empty not gate" unless any_matcher?(nested)

          validate_not_gate(
            nested,
            depth + 1,
            complexity
          )
        end
      end

      # Validate a gate nested under `not`, where any matcher suffices.
      def self.validate_not_gate(gate, depth, complexity)
        check_gate_budget(
          gate,
          "not gate",
          depth,
          complexity
        )
        raise InvalidManifest, "not gate must contain a matcher" unless any_matcher?(gate)

        gate.all.each do |nested|
          validate_gate(
            nested,
            "not all gate",
            depth + 1,
            complexity
          )
        end
        gate.any.each do |nested|
          validate_gate(
            nested,
            "not any gate",
            depth + 1,
            complexity
          )
        end
        gate.not_gate.each do |nested|
          validate_not_gate(
            nested,
            depth + 1,
            complexity
          )
        end
      end

      def self.check_gate_budget(gate, context, depth, complexity)
        raise InvalidManifest, "#{context} exceeds max gate depth #{MAX_GATE_DEPTH}" if depth > MAX_GATE_DEPTH

        complexity[:gates] += 1
        if complexity[:gates] > MAX_TOTAL_GATES
          raise InvalidManifest, "manifest exceeds max gate count #{MAX_TOTAL_GATES}"
        end

        validate_matcher_limits(
          gate,
          context,
          complexity
        )
      end

      def self.validate_matcher_limits(gate, context, complexity)
        count = gate.contains.length + gate.regex.length + gate.line_regex.length
        if count > MAX_MATCHERS_PER_GATE
          raise InvalidManifest, "#{context} has #{count} direct matchers, max is #{MAX_MATCHERS_PER_GATE}"
        end

        complexity[:matchers] += count
        if complexity[:matchers] > MAX_TOTAL_MATCHERS
          raise InvalidManifest, "manifest exceeds max matcher count #{MAX_TOTAL_MATCHERS}"
        end

        (gate.contains + gate.regex + gate.line_regex).each do |value|
          if value.length > MAX_MATCHER_CHARS
            raise InvalidManifest,
              "#{context} matcher exceeds max length #{MAX_MATCHER_CHARS}"
          end
        end
      end

      def self.positive_matcher?(gate)
        !gate.contains.empty? || !gate.regex.empty? || !gate.line_regex.empty? ||
          !gate.all.empty? || !gate.any.empty?
      end

      def self.any_matcher?(gate)
        positive_matcher?(gate) || !gate.not_gate.empty?
      end
      private_class_method :parse_rule,
        :rule_flags,
        :parse_gate,
        :gate_from,
        :gate_list,
        :string_list,
        :parse_int,
        :parse_bool,
        :parse_state,
        :reject_unknown_keys,
        :validate_manifest,
        :validate_rule,
        :validate_skip_state_update,
        :validate_region_name,
        :validate_gate,
        :validate_not_gate,
        :check_gate_budget,
        :validate_matcher_limits,
        :positive_matcher?,
        :any_matcher?
    end
  end
end
