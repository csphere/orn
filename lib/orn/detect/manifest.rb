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

      private_class_method :evaluate,
        :detection_for,
        :load_manifest,
        :cache,
        :load_uncached,
        :load_override,
        :load_bundled,
        :build_loaded,
        :manifest_matches_agent?,
        :gate_matches?,
        :leaf_matches?,
        :nested_matches?,
        :line_regex_matches?,
        :any_gate_matches?
    end
  end
end

require_relative "manifest_parse"
require_relative "manifest_regions"
require_relative "manifests"
