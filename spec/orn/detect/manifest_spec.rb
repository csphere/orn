# frozen_string_literal: true

RSpec.describe Orn::Detect::Manifest do
  def det(agent, screen: "", title: "", progress: "")
    described_class.detect(
      agent,
      described_class::DetectionInput.new(
        screen: screen,
        osc_title: title,
        osc_progress: progress
      )
    )
  end

  def region_of(screen, spec, title: "", progress: "")
    input = described_class::DetectionInput.new(
      screen: screen,
      osc_title: title,
      osc_progress: progress
    )
    described_class.region(input, spec)
  end

  def compiled_first(manifest_hash)
    described_class.compile_manifest(described_class.parse_manifest(manifest_hash)).first
  end

  def rule(fields)
    {
      "id" => "test",
      "rules" => [
        {
          "id" => "r",
          "state" => "working"
        }.merge(fields)
      ]
    }
  end

  describe ".parse_manifest" do
    it "parses a well-formed manifest" do
      manifest = described_class.parse_manifest(
        "id" => "test",
        "rules" => [
          {
            "id" => "rule_a",
            "state" => "working",
            "priority" => 100,
            "contains" => ["working"]
          },
          {
            "id" => "rule_b",
            "state" => "idle",
            "priority" => 50,
            "contains" => ["ready"]
          }
        ]
      )

      aggregate_failures do
        expect(manifest.id).to eq("test")
        expect(manifest.rules.map(&:id)).to eq(%w[rule_a rule_b])
      end
    end

    it "rejects a manifest with no rules" do
      expect { described_class.parse_manifest("id" => "test") }.to raise_error(described_class::InvalidManifest)
    end

    it "rejects a manifest exceeding the max rule count" do
      rules = Array.new(129) do |i|
        {
          "id" => "rule_#{i}",
          "state" => "idle",
          "contains" => ["ready"]
        }
      end

      expect do
        described_class.parse_manifest(
          "id" => "test",
          "rules" => rules
        )
      end
        .to raise_error(described_class::InvalidManifest)
    end

    it "rejects gate nesting deeper than the max" do
      gate = { "contains" => ["9"] }
      8.downto(1) do |i|
        gate = {
          "contains" => [i.to_s],
          "all" => [gate]
        }
      end

      expect do
        described_class.parse_manifest(
          rule(
            "contains" => ["ready"],
            "all" => [gate]
          )
        )
      end
        .to raise_error(described_class::InvalidManifest)
    end

    it "rejects a gate with only not matchers" do
      expect { described_class.parse_manifest(rule("not" => [{ "contains" => ["blocked"] }])) }
        .to raise_error(described_class::InvalidManifest)
    end

    it "rejects skip_state_update without state unknown" do
      manifest = rule(
        "state" => "idle",
        "skip_state_update" => true,
        "contains" => ["menu"]
      )

      expect { described_class.parse_manifest(manifest) }.to raise_error(described_class::InvalidManifest)
    end

    it "rejects a regex that does not compile" do
      expect { described_class.parse_manifest(rule("regex" => ["["])) }
        .to raise_error(described_class::InvalidManifest)
    end

    it "rejects an invalid nested regex" do
      expect { described_class.parse_manifest(rule("any" => [{ "line_regex" => ["["] }])) }
        .to raise_error(described_class::InvalidManifest)
    end

    it "rejects unknown fields" do
      expect { described_class.parse_manifest(rule("contain" => ["Working"])) }
        .to raise_error(described_class::InvalidManifest)
    end

    it "rejects an invalid region" do
      expect do
        described_class.parse_manifest(
          rule(
            "region" => "nonexistent_region",
            "contains" => ["test"]
          )
        )
      end
        .to raise_error(described_class::InvalidManifest)
    end

    it "rejects too many matchers in a single gate" do
      needles = Array.new(33) { |i| "m#{i}" }

      expect do
        described_class.parse_manifest(
          rule(
            "state" => "idle",
            "contains" => needles
          )
        )
      end
        .to raise_error(described_class::InvalidManifest)
    end
  end

  describe ".region" do
    it "returns the full content for whole_recent" do
      content = "line one\nline two\nline three"

      expect(region_of(content, "whole_recent")).to eq(content)
    end

    it "returns the last n lines for bottom_lines(n)" do
      expect(region_of("a\nb\nc\nd\ne", "bottom_lines(3)")).to eq("c\nd\ne")
    end

    it "skips trailing blanks for bottom_non_empty_lines(n)" do
      expect(region_of("a\nb\nc\n\n\n", "bottom_non_empty_lines(2)")).to eq("b\nc\n\n\n")
    end

    it "counts from the bottom-most occurrence for bottom_non_empty_lines(n)" do
      expect(region_of("marker\nold\n\nmiddle\nmarker\nnew\n", "bottom_non_empty_lines(2)")).to eq("marker\nnew\n")
    end

    it "extracts between the box rules for prompt_box_body" do
      content = "above\n─────────\nbody line 1\nbody line 2\n─────────\nbelow"

      expect(region_of(content, "prompt_box_body")).to eq("body line 1\nbody line 2\n")
    end

    it "returns content above the top border for above_prompt_box" do
      expect(region_of("above\n─────────\nbody\n─────────\nbelow", "above_prompt_box")).to eq("above\n")
    end

    it "returns content after the last rule for after_last_horizontal_rule" do
      expect(region_of("before\n─────────\nmiddle\n─────────\nafter this", "after_last_horizontal_rule"))
        .to eq("after this")
    end

    it "returns the title field for osc_title" do
      expect(
        region_of(
          "screen",
          "osc_title",
          title: "the title"
        )
      ).to eq("the title")
    end

    it "returns content after the last marker line for after_last_prompt_marker" do
      content = "output line 1\n› some prompt\nresponse line\n› another prompt\nfinal output"

      expect(region_of(content, "after_last_prompt_marker")).to eq("final output")
    end

    it "returns all content when there is no marker for after_last_prompt_marker" do
      content = "line one\nline two\nline three"

      expect(region_of(content, "after_last_prompt_marker")).to eq(content)
    end

    it "returns content before the last marker line for before_last_prompt_marker" do
      content = "output line 1\n› first prompt\nresponse\n› second prompt\nfinal"

      expect(region_of(content, "before_last_prompt_marker")).to eq("output line 1\n› first prompt\nresponse\n")
    end

    it "returns all content when there is no marker for before_last_prompt_marker" do
      content = "no markers here\njust text"

      expect(region_of(content, "before_last_prompt_marker")).to eq(content)
    end
  end

  describe ".horizontal_rule?" do
    it "matches dash-only and dash-labelled rules but not short or plain lines" do
      aggregate_failures do
        expect(described_class.horizontal_rule?("─────")).to be(true)
        expect(described_class.horizontal_rule?("─── context")).to be(true)
        expect(described_class.horizontal_rule?("")).to be(false)
        expect(described_class.horizontal_rule?("plain text")).to be(false)
        expect(described_class.horizontal_rule?("─ short")).to be(false)
      end
    end
  end

  describe "matcher evaluation" do
    it "matches contains case-insensitively" do
      expect(
        described_class.gate_matches_text?(
          compiled_first(rule("contains" => ["hello"])),
          "HELLO WORLD"
        )
      ).to be(true)
    end

    it "requires every contains string to be present" do
      gate = compiled_first(rule("contains" => %w[hello world]))

      aggregate_failures do
        expect(described_class.gate_matches_text?(gate, "hello world")).to be(true)
        expect(described_class.gate_matches_text?(gate, "hello")).to be(false)
      end
    end

    it "matches regex against the full region" do
      gate = compiled_first(rule("regex" => ["^hello"]))

      aggregate_failures do
        expect(described_class.gate_matches_text?(gate, "hello world")).to be(true)
        expect(described_class.gate_matches_text?(gate, "say hello")).to be(false)
      end
    end

    it "matches line_regex per line" do
      gate = compiled_first(rule("line_regex" => ["^exact$"]))

      aggregate_failures do
        expect(described_class.gate_matches_text?(gate, "before\nexact\nafter")).to be(true)
        expect(described_class.gate_matches_text?(gate, "not exact match")).to be(false)
      end
    end

    it "requires every nested gate for all" do
      gate = compiled_first(
        rule(
          "contains" => ["root"],
          "all" => [{ "contains" => ["xx"] }, { "contains" => ["yy"] }]
        )
      )

      aggregate_failures do
        expect(described_class.gate_matches_text?(gate, "root xx yy")).to be(true)
        expect(described_class.gate_matches_text?(gate, "root xx")).to be(false)
      end
    end

    it "requires at least one nested gate for any" do
      gate = compiled_first(
        rule(
          "contains" => ["base"],
          "any" => [{ "contains" => ["x"] }, { "contains" => ["y"] }]
        )
      )

      aggregate_failures do
        expect(described_class.gate_matches_text?(gate, "base x")).to be(true)
        expect(described_class.gate_matches_text?(gate, "base y")).to be(true)
        expect(described_class.gate_matches_text?(gate, "base z")).to be(false)
      end
    end

    it "treats an empty any gate as vacuously true" do
      gate = compiled_first(
        rule(
          "contains" => ["base"],
          "any" => []
        )
      )

      expect(described_class.gate_matches_text?(gate, "base")).to be(true)
    end

    it "fails when any not gate matches" do
      gate = compiled_first(
        rule(
          "contains" => ["base"],
          "not" => [{ "contains" => ["blocked"] }]
        )
      )

      aggregate_failures do
        expect(described_class.gate_matches_text?(gate, "base ok")).to be(true)
        expect(described_class.gate_matches_text?(gate, "base blocked")).to be(false)
      end
    end
  end

  describe "priority and fallback" do
    it "lets the higher-priority rule win" do
      manifest = described_class.parse_manifest(
        "id" => "test",
        "rules" => [
          {
            "id" => "low",
            "state" => "idle",
            "priority" => 10,
            "contains" => ["match"]
          },
          {
            "id" => "high",
            "state" => "working",
            "priority" => 100,
            "contains" => ["match"]
          }
        ]
      )
      input = described_class::DetectionInput.new(
        screen: "match",
        osc_title: "",
        osc_progress: ""
      )

      expect(described_class.evaluate_manifest(manifest, input).state).to eq(:working)
    end

    it "falls back to idle for a known agent with no match" do
      result = det(:claude, screen: "plain text with no patterns")

      aggregate_failures do
        expect(result.state).to eq(:idle)
        expect(result.visible_idle).to be(false)
      end
    end
  end

  describe "claude detection" do
    it "reads a braille spinner in the osc title as working" do
      expect(det(:claude, title: "\u{2802} project")).to have_attributes(
        state: :working,
        visible_working: true
      )
    end

    it "reads a prompt in the prompt box as idle" do
      screen = "output\n─────────\n  ❯ type here\n─────────\nfooter"

      expect(det(:claude, screen: screen)).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "reads a bash permission prompt as blocked" do
      screen = "do you want to proceed?\n" \
        "bash command: rm -rf /tmp/test\n" \
        "❯ 1. Yes\n   2. No\n\n" \
        "Esc to cancel \u{00B7} Tab to amend \u{00B7} ctrl+e to explain\n"

      expect(det(:claude, screen: screen)).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end

    it "reads a live blocked form as blocked" do
      screen = "──────────\n  1. Yes\n  2. No\n\n" \
        "Enter to select \u{00B7} \u{2191}/\u{2193} to navigate \u{00B7} Esc to cancel\n"

      expect(det(:claude, screen: screen)).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end

    it "skips the state update for the transcript viewer" do
      screen = "some content\nshowing detailed transcript\nctrl+o to toggle\n"

      expect(det(:claude, screen: screen).skip_state_update).to be(true)
    end

    it "reads a star in the osc title as idle" do
      expect(det(:claude, title: "\u{2733} Claude Code")).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "reads an osc progress of 4;0 as idle" do
      expect(det(:claude, progress: "4;0;").state).to eq(:idle)
    end

    it "falls back to idle with no visible evidence when nothing matches" do
      expect(det(:claude, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end

    it "lets a blocker outrank an idle osc title" do
      screen = "do you want to proceed?\n" \
        "bash command: rm -rf /tmp/test\n" \
        "❯ 1. Yes\n   2. No\n\n" \
        "Esc to cancel \u{00B7} Tab to amend \u{00B7} ctrl+e to explain\n"

      detection = det(
        :claude,
        screen: screen,
        title: "\u{2733} Claude Code"
      )

      expect(detection).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end
  end

  describe "codex detection" do
    it "reads a braille osc title as working" do
      expect(det(:codex, title: "\u{2802} myproject")).to have_attributes(
        state: :working,
        visible_working: true
      )
    end

    it "reads the working status indicator as working" do
      expect(det(:codex, screen: "• Working (47s • esc to interrupt)\n"))
        .to have_attributes(
          state: :working,
          visible_working: true
        )
    end

    it "reads sandbox execution as working" do
      expect(det(:codex, screen: "✓ Previous task 2s\nexecuting in sandbox\n"))
        .to have_attributes(
          state: :working,
          visible_working: true
        )
    end

    it "reads an approval prompt as blocked" do
      expect(det(:codex, screen: "I want to run: rm -rf /tmp/test\nApprove? (y/n)\n"))
        .to have_attributes(
          state: :blocked,
          visible_blocker: true
        )
    end

    it "reads apply-changes as blocked" do
      expect(det(:codex, screen: "Apply changes?\n")).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end

    it "reads an idle prompt as idle" do
      expect(det(:codex, screen: "✓ Task completed 3s\nSome output here\n›\n"))
        .to have_attributes(
          state: :idle,
          visible_idle: true
        )
    end

    it "reads a completed block as idle" do
      expect(det(:codex, screen: "✓ Updated file.rb 2s\nChanges applied.\n"))
        .to have_attributes(
          state: :idle,
          visible_idle: true
        )
    end

    it "falls back to idle when nothing matches" do
      expect(det(:codex, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end
  end

  describe "pi detection" do
    it "reads osc progress 9;4 as working" do
      expect(det(:pi, progress: "9;4;50")).to have_attributes(
        state: :working,
        visible_working: true
      )
    end

    it "reads a spinner as working" do
      expect(det(:pi, screen: "\u{2802} Processing request\nReading files...\n"))
        .to have_attributes(
          state: :working,
          visible_working: true
        )
    end

    it "reads a trust prompt as blocked" do
      expect(
        det(
          :pi,
          screen: "Trust this project folder?\n"
        )
      ).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end

    it "reads an idle prompt as idle" do
      expect(det(:pi, screen: "Output complete\n❯\n")).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "falls back to idle when nothing matches" do
      expect(det(:pi, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end
  end

  describe "gemini detection" do
    it "reads a spinner as working" do
      expect(det(:gemini, screen: "\u{280F} Searching for files...\n"))
        .to have_attributes(
          state: :working,
          visible_working: true
        )
    end

    it "reads a permission prompt as blocked" do
      screen = "Allow this action?\n1. Yes, allow once\n2. Yes, allow always\n3. No, suggest changes\n"

      expect(det(:gemini, screen: screen)).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end

    it "reads an idle prompt as idle" do
      expect(det(:gemini, screen: "Response complete\n❯\n")).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "falls back to idle when nothing matches" do
      expect(det(:gemini, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end
  end

  describe "cursor detection" do
    it "reads a spinner as working" do
      expect(det(:cursor, screen: "\u{2802} Running tool: read_file\n"))
        .to have_attributes(
          state: :working,
          visible_working: true
        )
    end

    it "reads a permission prompt as blocked" do
      expect(det(:cursor, screen: "Allow this action?\n(y)es  (n)o\n"))
        .to have_attributes(
          state: :blocked,
          visible_blocker: true
        )
    end

    it "reads an idle prompt as idle" do
      expect(det(:cursor, screen: "Done.\n>\n")).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "falls back to idle when nothing matches" do
      expect(det(:cursor, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end
  end

  describe "devin detection" do
    it "reads running-tools as working" do
      expect(det(:devin, screen: "Running tools, esc to interrupt\n"))
        .to have_attributes(
          state: :working,
          visible_working: true
        )
    end

    it "reads a spinner as working" do
      expect(
        det(
          :devin,
          screen: "\u{2802} Working on task\n"
        )
      ).to have_attributes(
        state: :working,
        visible_working: true
      )
    end

    it "reads an allow-once prompt as blocked" do
      screen = "Execute rm -rf /tmp/test?\nAllow once | Allow for session | Allow for project | Allow globally\n"

      expect(det(:devin, screen: screen)).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end

    it "reads a hash prompt as idle" do
      expect(det(:devin, screen: "Task complete.\n#\n")).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "falls back to idle when nothing matches" do
      expect(det(:devin, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end
  end

  describe "amp detection" do
    it "reads a spinner as working" do
      expect(det(:amp, screen: "\u{2802} Executing tool\n")).to have_attributes(
        state: :working,
        visible_working: true
      )
    end

    it "reads awaiting-approval as blocked" do
      expect(det(:amp, screen: "Awaiting approval for MCP tool call\n"))
        .to have_attributes(
          state: :blocked,
          visible_blocker: true
        )
    end

    it "reads an idle prompt as idle" do
      expect(det(:amp, screen: "Done.\n>\n")).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "falls back to idle when nothing matches" do
      expect(det(:amp, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end
  end

  describe "kiro detection" do
    it "reads a pending-approval title as blocked" do
      expect(det(:kiro, title: "pending approval")).to have_attributes(
        state: :blocked,
        visible_blocker: true
      )
    end

    it "reads a streaming title as working" do
      expect(det(:kiro, title: "streaming")).to have_attributes(
        state: :working,
        visible_working: true
      )
    end

    it "reads a pause icon as blocked" do
      expect(det(:kiro, screen: "⏸ Awaiting approval\nYes  Trust  No\n"))
        .to have_attributes(
          state: :blocked,
          visible_blocker: true
        )
    end

    it "reads a yes/trust/no panel as blocked" do
      expect(det(:kiro, screen: "Execute: git pull --rebase\nYes  Trust  No\n"))
        .to have_attributes(
          state: :blocked,
          visible_blocker: true
        )
    end

    it "reads a spinner as working" do
      expect(
        det(
          :kiro,
          screen: "\u{2802} Generating code\n"
        )
      ).to have_attributes(
        state: :working,
        visible_working: true
      )
    end

    it "reads an idle prompt as idle" do
      expect(det(:kiro, screen: "Done.\n>\n")).to have_attributes(
        state: :idle,
        visible_idle: true
      )
    end

    it "falls back to idle when nothing matches" do
      expect(det(:kiro, screen: "plain text")).to have_attributes(
        state: :idle,
        visible_idle: false
      )
    end
  end

  describe "cross-agent false positives" do
    def quiet_state?(state)
      !%i[working blocked].include?(state)
    end

    it "does not trigger pi on claude output" do
      screen = "output\n─────────\n  ❯ type here\n─────────\nfooter"

      expect(quiet_state?(det(:pi, screen: screen).state)).to be(true)
    end

    it "does not trigger codex on claude output" do
      screen = "output\n─────────\n  ❯ type here\n─────────\nfooter"

      expect(quiet_state?(det(:codex, screen: screen).state)).to be(true)
    end

    it "does not trigger claude on codex output" do
      state = det(:claude, screen: "✓ Task completed 3s\nSome output here\n›\n").state

      expect(quiet_state?(state)).to be(true)
    end
  end

  describe "bundled manifests" do
    it "parses and compiles every bundled manifest" do
      aggregate_failures do
        Orn::Detect::AGENTS.each do |agent|
          raw = described_class::BUNDLED_MANIFESTS[agent.to_s]

          expect { described_class.compile_manifest(described_class.parse_manifest(raw)) }
            .not_to raise_error, "#{agent} manifest should compile"
        end
      end
    end
  end
end
