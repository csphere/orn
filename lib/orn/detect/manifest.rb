# frozen_string_literal: true

require "yaml"

module Orn
  module Detect
    # Rule-based agent state detection driven by declarative manifests. A
    # manifest per agent is bundled with the gem (see manifests.rb); a user
    # override in `<global_config_dir>/agent-detection/<agent>.yaml` takes
    # precedence when valid. States are symbols (`:idle`, `:working`, ...).
    module Manifest
      # Raised when a manifest is structurally invalid or fails a complexity
      # cap. Override loads swallow it (falling back to the bundled manifest);
      # a bundled manifest raising it is a build defect.
      class InvalidManifest < StandardError; end

      # Text inputs rules are evaluated against. `osc_progress` is not yet
      # captured in production: both call sites in detect/mod.rb pass "", so
      # manifest rules on the osc_progress region only fire in tests until
      # OSC progress capture is wired up. Do not key new manifest rules off
      # it expecting a runtime effect.
      DetectionInput = Data.define(
        :screen,
        :osc_title,
        :osc_progress
      )

      # Result of manifest evaluation: the derived state, which kinds of visible
      # evidence backed it, and whether the caller should keep its previous
      # state (`skip_state_update`, e.g. a transcript viewer).
      AgentDetection = Data.define(
        :state,
        :visible_idle,
        :visible_blocker,
        :visible_working,
        :skip_state_update
      ) do
        # Fallback when no rule matches or no manifest is available.
        def self.idle
          new(
            state: :idle,
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
            skip_state_update: false
          )
        end
      end

      # A boolean matcher node: leaves (`contains`/`regex`/`line_regex`)
      # combined with nested `all`/`any`/`not_gate` gates.
      Gate = Data.define(
        :all,
        :any,
        :not_gate,
        :contains,
        :regex,
        :line_regex
      )

      # One detection rule: its matcher gate over a screen `region`, mapping to
      # a `state`. Among matching rules the highest `priority` wins.
      Rule = Data.define(
        :id,
        :state,
        :priority,
        :region,
        :visible_idle,
        :visible_blocker,
        :visible_working,
        :skip_state_update,
        :gate
      )

      # A compiled gate: `contains` needles lowercased, patterns built to Regexp.
      CompiledGate = Data.define(
        :all,
        :any,
        :not_gate,
        :contains,
        :regex,
        :line_regex
      )

      # A parsed manifest: id, aliases, and rules.
      ParsedManifest = Data.define(
        :id,
        :aliases,
        :rules
      )

      # A parsed manifest paired with its per-rule compiled gates.
      Loaded = Data.define(:rules, :compiled_gates)

      DEFAULT_REGION = "whole_recent"

      MANIFEST_KEYS = %w[id aliases rules].freeze
      RULE_KEYS = %w[
        id
        state
        priority
        region
        visible_idle
        visible_blocker
        visible_working
        skip_state_update
        all
        any
        not
        contains
        regex
        line_regex
      ].freeze
      GATE_KEYS = %w[all any not contains regex line_regex].freeze
      STATES = {
        "idle" => :idle,
        "working" => :working,
        "blocked" => :blocked,
        "unknown" => :unknown
      }.freeze

      REGION_NAMES = %w[
        whole_recent
        prompt_box_body
        above_prompt_box
        after_last_horizontal_rule
        after_last_prompt_marker
        before_last_prompt_marker
        osc_title
        osc_progress
      ].freeze

      # Complexity caps protecting against pathological (user override) manifests.
      MAX_RULES_PER_MANIFEST = 128
      MAX_GATE_DEPTH = 8
      MAX_TOTAL_GATES = 512
      MAX_MATCHERS_PER_GATE = 32
      MAX_TOTAL_MATCHERS = 1024
      MAX_MATCHER_CHARS = 512

      PROMPT_MARKER = "›"

      # Evaluate `agent`'s manifest against `input`. Falls back to a bare idle
      # result when no manifest loads or no rule matches.
      def self.detect(agent, input)
        loaded = load_manifest(agent)
        return AgentDetection.idle if loaded.nil?

        evaluate(loaded, input)
      end

      # Run every rule against its region and return the highest-priority match.
      # Region text and its lowercase form are computed once per distinct region.
      def self.evaluate(loaded, input)
        lines = split_lines(input.screen)
        region_cache = {}
        matched = nil

        loaded.rules.each_with_index do |rule, index|
          text, lower = region_cache[rule.region] ||= begin
            region = region_with_lines(
              input,
              lines,
              rule.region
            )
            [region, region.downcase]
          end
          next unless gate_matches?(
            loaded.compiled_gates[index],
            text,
            lower
          )

          matched = rule if matched.nil? || matched.priority < rule.priority
        end

        matched.nil? ? AgentDetection.idle : detection_for(matched)
      end

      # For tests: compile a parsed manifest and evaluate it against an input
      # without going through the bundled-manifest cache.
      def self.evaluate_manifest(manifest, input)
        evaluate(build_loaded(manifest), input)
      end

      def self.detection_for(rule)
        state = rule.state || :unknown
        AgentDetection.new(
          state: state,
          visible_idle: rule.visible_idle && state == :idle,
          visible_blocker: rule.visible_blocker && state == :blocked,
          visible_working: rule.visible_working && state == :working,
          skip_state_update: rule.skip_state_update
        )
      end

      # --- Loading + caching ---

      def self.load_manifest(agent)
        cache[agent]
      end

      # Per-agent cache built once per process; nil records a failed load.
      def self.cache
        @cache ||= Detect::AGENTS.to_h { |agent| [agent, load_uncached(agent)] }
      end

      # Resets the memoized cache; for tests exercising override loading.
      def self.reset_cache!
        @cache = nil
      end

      def self.load_uncached(agent)
        load_override(agent) || load_bundled(agent)
      end

      # A user override from the global config dir, or nil when absent/invalid.
      def self.load_override(agent)
        dir = Orn::Config.global_config_dir
        return nil if dir.nil?

        path = File.join(
          dir,
          "agent-detection",
          "#{agent}.yaml"
        )
        return nil unless File.exist?(path)

        manifest = parse_manifest(YAML.safe_load_file(path))
        return nil unless manifest_matches_agent?(manifest, agent)

        build_loaded(manifest)
      rescue InvalidManifest, Psych::SyntaxError, SystemCallError
        nil
      end

      # The bundled manifest. Raises InvalidManifest if it is malformed: that is
      # a build defect, not a runtime condition.
      def self.load_bundled(agent)
        raw = BUNDLED_MANIFESTS[agent.to_s]
        return nil if raw.nil?

        build_loaded(parse_manifest(raw))
      end

      def self.build_loaded(manifest)
        Loaded.new(
          rules: manifest.rules,
          compiled_gates: compile_manifest(manifest)
        )
      end

      def self.manifest_matches_agent?(manifest, agent)
        label = agent.to_s
        manifest.id == label || manifest.aliases.include?(label)
      end

      # --- Parsing + validation ---

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

      # --- Compilation ---

      def self.compile_manifest(manifest)
        manifest.rules.map do |rule|
          compile_gate(rule.gate)
        rescue InvalidManifest => e
          raise InvalidManifest, "rule #{rule.id} could not be compiled: #{e.message}"
        end
      end

      def self.compile_gate(gate)
        CompiledGate.new(
          all: gate.all.map { |nested| compile_gate(nested) },
          any: gate.any.map { |nested| compile_gate(nested) },
          not_gate: gate.not_gate.map { |nested| compile_gate(nested) },
          contains: gate.contains.map(&:downcase),
          regex: gate.regex.map { |pattern| compile_regex(pattern) },
          line_regex: gate.line_regex.map { |pattern| compile_regex(pattern) }
        )
      end

      def self.compile_regex(pattern)
        Regexp.new(pattern)
      rescue RegexpError => e
        raise InvalidManifest, e.message
      end

      # --- Matching ---

      # True when every matcher holds: `contains` case-insensitive, `regex` on
      # the whole region, `line_regex` on at least one line, `all` needs every
      # nested gate, non-empty `any` needs one, no `not_gate` may match.
      def self.gate_matches?(gate, text, lower_text)
        leaf_matches?(
          gate,
          text,
          lower_text
        ) && nested_matches?(
          gate,
          text,
          lower_text
        )
      end

      def self.leaf_matches?(gate, text, lower_text)
        gate.contains.all? { |needle| lower_text.include?(needle) } &&
          gate.regex.all? { |regex| regex.match?(text) } &&
          line_regex_matches?(gate, text)
      end

      def self.nested_matches?(gate, text, lower_text)
        gate.all.all? do |nested|
          gate_matches?(
            nested,
            text,
            lower_text
          )
        end &&
          any_gate_matches?(
            gate,
            text,
            lower_text
          ) &&
          gate.not_gate.none? do |nested|
            gate_matches?(
              nested,
              text,
              lower_text
            )
          end
      end

      def self.line_regex_matches?(gate, text)
        return true if gate.line_regex.empty?

        lines = split_lines(text)
        gate.line_regex.all? { |regex| lines.any? { |line| regex.match?(line) } }
      end

      # A non-empty `any` needs one nested gate to match; an empty `any` is
      # vacuously true.
      def self.any_gate_matches?(gate, text, lower_text)
        gate.any.empty? || gate.any.any? do |nested|
          gate_matches?(
            nested,
            text,
            lower_text
          )
        end
      end

      # For tests: match a compiled gate against text (lowercasing internally).
      def self.gate_matches_text?(gate, text)
        gate_matches?(
          gate,
          text,
          text.downcase
        )
      end

      # --- Region extraction ---

      # For tests: extract a region from an input using a fresh line split.
      def self.region(input, spec)
        region_with_lines(
          input,
          split_lines(input.screen),
          spec
        )
      end

      # Extract the text a rule's `region` spec refers to. `lines` must be
      # `split_lines(input.screen)` precomputed by the caller; unknown specs
      # yield an empty region.
      def self.region_with_lines(input, lines, spec)
        trimmed = spec.strip
        return input.osc_title if trimmed == "osc_title"
        return input.osc_progress if trimmed == "osc_progress"

        content = input.screen
        box_region(
          content,
          lines,
          trimmed
        ) ||
          marker_region(content, trimmed) ||
          parameterized_region(
            content,
            lines,
            trimmed
          )
      end

      def self.box_region(content, lines, trimmed)
        case trimmed
        when "whole_recent" then content
        when "prompt_box_body" then prompt_box_body(content, lines) || ""
        when "above_prompt_box" then above_prompt_box(content, lines)
        when "after_last_horizontal_rule" then after_last_horizontal_rule(content)
        end
      end

      def self.marker_region(content, trimmed)
        case trimmed
        when "after_last_prompt_marker" then after_last_prompt_marker(content, PROMPT_MARKER)
        when "before_last_prompt_marker" then before_last_prompt_marker(content, PROMPT_MARKER)
        end
      end

      def self.parameterized_region(content, lines, trimmed)
        count = region_count(trimmed, "bottom_lines")
        unless count.nil?
          return bottom_lines(
            content,
            lines,
            count
          )
        end

        count = region_count(trimmed, "bottom_non_empty_lines")
        unless count.nil?
          return bottom_non_empty_lines(
            content,
            lines,
            count
          )
        end

        ""
      end

      # Parse the count out of a `name(count)` region spec.
      def self.region_count(spec, name)
        return nil unless spec.start_with?(name)

        rest = spec[name.length..]
        return nil unless rest.start_with?("(") && rest.end_with?(")")

        count = Integer(
          rest[1...-1],
          10,
          exception: false
        )
        count.nil? || count.negative? ? nil : count
      end

      # The suffix of `content` starting at the `count`-th line from the bottom.
      def self.bottom_lines(content, lines, count)
        slice_from_line_index(
          content,
          lines,
          [lines.length - count, 0].max
        )
      end

      # The suffix starting at the `count`-th non-empty line from the bottom;
      # blank lines in between and trailing blanks are kept.
      def self.bottom_non_empty_lines(content, lines, count)
        non_empty = lines.each_index.reject { |index| lines[index].strip.empty? }
        chosen = non_empty.last(count).first
        return "" if chosen.nil?

        slice_from_line_index(
          content,
          lines,
          chosen
        )
      end

      # The lines between the prompt box's top border and the next horizontal
      # rule below it (or the end of the screen); nil when there is no box.
      def self.prompt_box_body(content, lines)
        top = prompt_box_top_border_index(lines)
        return nil if top.nil?

        start = line_start_offset(
          content,
          lines,
          top + 1
        )
        relative = lines[(top + 1)..].index { |line| horizontal_rule?(line) }
        end_index = relative.nil? ? lines.length : top + 1 + relative
        finish = line_start_offset(
          content,
          lines,
          end_index
        )
        content[[start, content.length].min...[finish, content.length].min]
      end

      # Everything above the prompt box's top border, or the whole screen when
      # no prompt box is found.
      def self.above_prompt_box(content, lines)
        top = prompt_box_top_border_index(lines)
        return content if top.nil?

        content[0...[
          line_start_offset(
            content,
            lines,
            top
          ),
          content.length
        ].min]
      end

      # Content after the last horizontal rule line; the whole content when none.
      def self.after_last_horizontal_rule(content)
        last_rule_end = 0
        offset = 0
        split_lines(content).each do |line|
          next_offset = offset + line.length + 1
          last_rule_end = [next_offset, content.length].min if horizontal_rule?(line)
          offset = next_offset
        end
        content[last_rule_end..]
      end

      # Line index of the prompt box's top border: the second horizontal rule
      # counting up from the bottom (the bottom rule closes the box).
      def self.prompt_box_top_border_index(lines)
        border_count = 0
        (lines.length - 1).downto(0) do |index|
          next unless horizontal_rule?(lines[index])

          border_count += 1
          return index if border_count == 2
        end
        nil
      end

      # True for a line of box-drawing dashes: dashes only, or at least three
      # leading dashes followed by text (e.g. `─── context`).
      def self.horizontal_rule?(line)
        trimmed = line.strip
        return false if trimmed.empty?

        rule_chars = trimmed.each_char.take_while { |char| char == "─" }.length
        return false if rule_chars.zero?

        suffix = (trimmed[rule_chars..] || "").lstrip
        suffix.empty? || rule_chars >= 3
      end

      # Content after the last line starting with `marker`; the whole content
      # when no line does.
      def self.after_last_prompt_marker(content, marker)
        last_marker_end = 0
        offset = 0
        split_lines(content).each do |line|
          next_offset = offset + line.length + 1
          last_marker_end = [next_offset, content.length].min if line.start_with?(marker)
          offset = next_offset
        end
        content[last_marker_end..]
      end

      # Content before the last line starting with `marker`; the whole content
      # when no line does.
      def self.before_last_prompt_marker(content, marker)
        last_marker_start = content.length
        offset = 0
        split_lines(content).each do |line|
          last_marker_start = offset if line.start_with?(marker)
          offset += line.length + 1
        end
        content[0...[last_marker_start, content.length].min]
      end

      def self.slice_from_line_index(content, lines, index)
        content[[
          line_start_offset(
            content,
            lines,
            index
          ),
          content.length
        ].min..]
      end

      # Character offset where line `index` starts, assuming one-char `\n`
      # separators; clamped to the content length.
      def self.line_start_offset(content, lines, index)
        offset = lines[0...[index, lines.length].min].sum { |line| line.length + 1 }
        [offset, content.length].min
      end

      # Split into lines on `\n`, stripping a trailing `\r`,
      # with no empty final element from a terminating newline.
      def self.split_lines(text)
        return [] if text.empty?

        parts = text.split("\n", -1)
        parts.pop if text.end_with?("\n")
        parts.map { |line| line.end_with?("\r") ? line[0...-1] : line }
      end

      private_class_method :evaluate,
        :detection_for,
        :load_manifest,
        :cache,
        :load_uncached,
        :load_override,
        :load_bundled,
        :build_loaded,
        :manifest_matches_agent?,
        :parse_rule,
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
        :any_matcher?,
        :gate_matches?,
        :leaf_matches?,
        :nested_matches?,
        :line_regex_matches?,
        :any_gate_matches?,
        :region_with_lines,
        :box_region,
        :marker_region,
        :parameterized_region,
        :bottom_lines,
        :bottom_non_empty_lines,
        :prompt_box_body,
        :above_prompt_box,
        :after_last_horizontal_rule,
        :prompt_box_top_border_index,
        :after_last_prompt_marker,
        :before_last_prompt_marker,
        :slice_from_line_index,
        :line_start_offset
    end
  end
end

require_relative "manifests"
