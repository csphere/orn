# frozen_string_literal: true

RSpec.describe Orn::Detect do
  def process(pid, name, argv = nil)
    Orn::Detect::ForegroundProcess.new(
      pid: pid,
      name: name,
      argv: argv
    )
  end

  def job(pgid, processes)
    Orn::Detect::ForegroundJob.new(
      process_group_id: pgid,
      processes: processes
    )
  end

  def pane(window:, command:, pane_id:, title: "")
    Orn::Tmux::PaneMetadata.new(
      session_name: nil,
      window_name: window,
      pane_pid: 99_999,
      pane_title: title,
      pane_current_command: command,
      pane_id: pane_id
    )
  end

  describe ".identify_agent" do
    it "matches known agents and their aliases" do
      cases = {
        "claude" => :claude,
        "claude-code" => :claude,
        "pi" => :pi,
        "codex" => :codex,
        "gemini" => :gemini,
        "cursor" => :cursor,
        "cursor-agent" => :cursor,
        "devin" => :devin,
        "devin-cli" => :devin,
        "amp" => :amp,
        "amp-local" => :amp,
        "kiro" => :kiro,
        "kiro-cli" => :kiro
      }

      aggregate_failures do
        cases.each { |name, agent| expect(described_class.identify_agent(name)).to eq(agent) }
      end
    end

    it "returns nil for non-agents" do
      aggregate_failures do
        %w[bash zsh vim node].each { |name| expect(described_class.identify_agent(name)).to be_nil }
      end
    end

    it "is case insensitive" do
      aggregate_failures do
        expect(described_class.identify_agent("Claude")).to eq(:claude)
        expect(described_class.identify_agent("CLAUDE")).to eq(:claude)
        expect(described_class.identify_agent("Pi")).to eq(:pi)
      end
    end

    it "strips known wrapper extensions" do
      aggregate_failures do
        expect(described_class.identify_agent("claude.exe")).to eq(:claude)
        expect(described_class.identify_agent("codex.cmd")).to eq(:codex)
        expect(described_class.identify_agent("gemini.bat")).to eq(:gemini)
        expect(described_class.identify_agent("devin.ps1")).to eq(:devin)
        expect(described_class.identify_agent("amp.js")).to eq(:amp)
      end
    end

    it "strips the path to the basename" do
      aggregate_failures do
        expect(described_class.identify_agent("/usr/bin/claude")).to eq(:claude)
        expect(described_class.identify_agent("/home/user/.local/bin/codex")).to eq(:codex)
        expect(described_class.identify_agent("C:\\Users\\bin\\gemini.exe")).to eq(:gemini)
      end
    end
  end

  describe ".identify_agent_in_job" do
    it "prefers the process group leader" do
      j = job(
        100,
        [
          process(100, "claude"),
          process(
            101,
            "node",
            ["node", "/path/to/codex"]
          )
        ]
      )

      expect(described_class.identify_agent_in_job(j).first).to eq(:claude)
    end

    it "falls back to a wrapped agent when the leader is a runtime" do
      j = job(
        100,
        [
          process(
            100,
            "node",
            ["node", "/path/to/bin/codex", "--model", "gpt-5"]
          )
        ]
      )

      expect(described_class.identify_agent_in_job(j)).to eq([:codex, "codex"])
    end

    it "detects a wrapped agent in a child process" do
      j = job(
        100,
        [
          process(
            100,
            "bash",
            ["bash"]
          ),
          process(
            101,
            "node",
            ["node", "/path/to/bin/codex"]
          )
        ]
      )

      expect(described_class.identify_agent_in_job(j).first).to eq(:codex)
    end

    it "skips non-eval flags before the script argument" do
      j = job(
        100,
        [
          process(
            100,
            "node",
            ["node", "--enable-source-maps", "/path/to/bin/codex"]
          )
        ]
      )

      expect(described_class.identify_agent_in_job(j)).to eq([:codex, "codex"])
    end

    it "returns nil when the wrapped script is not an agent" do
      j = job(
        100,
        [
          process(
            100,
            "node",
            ["node", "server.js"]
          )
        ]
      )

      expect(described_class.identify_agent_in_job(j)).to be_nil
    end

    it "matches an agent running as a non-leader process" do
      j = job(
        100,
        [
          process(
            100,
            "bash",
            ["bash"]
          ),
          process(101, "claude")
        ]
      )

      expect(described_class.identify_agent_in_job(j)).to eq([:claude, "claude"])
    end

    it "still matches when the group leader is absent from the process list" do
      j = job(
        100,
        [process(101, "claude")]
      )

      expect(described_class.identify_agent_in_job(j)).to eq([:claude, "claude"])
    end

    it "skips non-runtime processes and runtimes without argv in the wrapped scan" do
      j = job(
        100,
        [
          process(100, "vim"),
          process(101, "node")
        ]
      )

      expect(described_class.identify_agent_in_job(j)).to be_nil
    end

    it "ignores eval flags (subsequent args are inline code)" do
      j = job(
        100,
        [
          process(
            100,
            "python3",
            ["python3", "-c", "print('hi')", "/tmp/codex"]
          )
        ]
      )

      expect(described_class.identify_agent_in_job(j)).to be_nil
    end

    it "returns nil for shells only" do
      j = job(
        100,
        [
          process(
            100,
            "bash",
            ["bash"]
          ),
          process(
            101,
            "zsh",
            ["zsh"]
          )
        ]
      )

      expect(described_class.identify_agent_in_job(j)).to be_nil
    end
  end

  describe ".container_runtime?" do
    it "recognizes container runtimes" do
      aggregate_failures do
        %w[docker sbx podman nerdctl].each { |name| expect(described_class.container_runtime?(name)).to be(true) }
      end
    end

    it "does not recognize non-container commands" do
      aggregate_failures do
        %w[bash claude node python].each { |name| expect(described_class.container_runtime?(name)).to be(false) }
      end
    end
  end

  describe ".choose_agent_pane" do
    it "prefers the pane running an agent over a shell" do
      panes = [
        pane(
          window: "issues/1",
          command: "zsh",
          pane_id: "%1"
        ),
        pane(
          window: "issues/1",
          command: "claude",
          pane_id: "%2"
        )
      ]

      expect(described_class.choose_agent_pane(panes, "issues/1").pane_id).to eq("%2")
    end

    it "falls back to the first pane when no agent is present" do
      panes = [
        pane(
          window: "issues/1",
          command: "zsh",
          pane_id: "%1"
        ),
        pane(
          window: "issues/1",
          command: "vim",
          pane_id: "%2"
        )
      ]

      expect(described_class.choose_agent_pane(panes, "issues/1").pane_id).to eq("%1")
    end

    it "ignores panes in other windows" do
      panes = [
        pane(
          window: "main",
          command: "claude",
          pane_id: "%1"
        )
      ]

      expect(described_class.choose_agent_pane(panes, "issues/1")).to be_nil
    end
  end

  describe ".detect_pane" do
    let(:client) { FakeTmuxClient.new }

    # :real_cmd for the platform foreground-job probe (`ps`/`/proc`), not tmux:
    # pane capture goes through the fake client.
    context "with the real platform probe", :real_cmd do
      it "identifies claude from the pane command" do
        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "claude",
            pane_id: "%99"
          ),
          nil
        )

        expect(result.agent).to eq(:claude)
      end

      it "falls through to no agent for a shell" do
        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "bash",
            pane_id: "%99"
          ),
          nil
        )

        expect(result).to have_attributes(
          agent: nil,
          state: :unknown
        )
      end

      it "uses the sbx agent type when the command is a container runtime" do
        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "docker",
            pane_id: "%99"
          ),
          :claude
        )

        expect(result.agent).to eq(:claude)
      end

      it "reports no agent for a container runtime without an sbx agent type" do
        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "docker",
            pane_id: "%99"
          ),
          nil
        )

        expect(result).to have_attributes(
          agent: nil,
          state: :unknown
        )
      end

      it "skips the screen capture when the osc title is definitive" do
        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "claude",
            title: "\u{2802} project",
            pane_id: "%99"
          ),
          nil
        )

        aggregate_failures do
          expect(result).to have_attributes(
            agent: :claude,
            state: :working
          )
          expect(client.count(:capture_pane)).to eq(0)
        end
      end
    end

    context "with an injected foreground job source" do
      it "skips the screen capture and the job probe when the osc title is definitive" do
        probe_calls = []
        source = lambda do |pane_pid|
          probe_calls << pane_pid
          nil
        end

        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "claude",
            title: "\u{2802} project",
            pane_id: "%1"
          ),
          nil,
          foreground_job_source: source
        )

        aggregate_failures do
          expect(result).to have_attributes(
            agent: :claude,
            state: :working
          )
          expect(client.count(:capture_pane)).to eq(0)
          expect(probe_calls).to be_empty
        end
      end

      it "captures the screen when the osc title is not definitive" do
        client.captures["%1"] = <<~SCREEN
          Do you want to make this edit?
          ──────────────────────────────
          ❯ 1. Yes
            2. No

          enter to select · esc to cancel · arrow keys to navigate
        SCREEN

        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "claude",
            pane_id: "%1"
          ),
          nil,
          foreground_job_source: ->(_pane_pid) {}
        )

        aggregate_failures do
          expect(result).to have_attributes(
            agent: :claude,
            state: :blocked
          )
          expect(client.calls).to include([:capture_pane, "%1"])
        end
      end

      it "does not probe the foreground job when the pane command is an agent" do
        source = ->(_pane_pid) { raise "foreground job source must not be called" }

        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "claude",
            pane_id: "%1"
          ),
          nil,
          foreground_job_source: source
        )

        expect(result.agent).to eq(:claude)
      end

      it "treats a failed screen capture as an empty screen (idle fallback)" do
        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "claude",
            pane_id: "%1"
          ),
          nil,
          foreground_job_source: ->(_pane_pid) {}
        )

        aggregate_failures do
          expect(result).to have_attributes(
            agent: :claude,
            state: :idle
          )
          expect(client.count(:capture_pane)).to eq(1)
        end
      end

      it "identifies a wrapped agent through the foreground job" do
        probe_calls = []
        source = lambda do |pane_pid|
          probe_calls << pane_pid
          job(
            100,
            [
              process(
                100,
                "node",
                ["node", "/x/codex"]
              )
            ]
          )
        end

        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "bash",
            pane_id: "%1"
          ),
          nil,
          foreground_job_source: source
        )

        aggregate_failures do
          expect(result.agent).to eq(:codex)
          expect(probe_calls).to eq([99_999])
        end
      end

      it "prefers a job match over the container fallback" do
        source = ->(_pane_pid) { job(100, [process(100, "claude")]) }

        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "docker",
            pane_id: "%1"
          ),
          :gemini,
          foreground_job_source: source
        )

        expect(result.agent).to eq(:claude)
      end

      it "falls back to the sbx agent type when a container runtime has no job" do
        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "docker",
            pane_id: "%1"
          ),
          :claude,
          foreground_job_source: ->(_pane_pid) {}
        )

        expect(result.agent).to eq(:claude)
      end

      it "reports unknown without capturing when nothing is detected" do
        source = ->(_pane_pid) { job(100, [process(100, "bash", ["bash"])]) }

        result = described_class.detect_pane(
          client,
          pane(
            window: "w",
            command: "bash",
            pane_id: "%1"
          ),
          nil,
          foreground_job_source: source
        )

        aggregate_failures do
          expect(result).to have_attributes(
            agent: nil,
            state: :unknown
          )
          expect(client.count(:capture_pane)).to eq(0)
        end
      end
    end
  end

  describe ".detect_all_panes" do
    let(:client) { FakeTmuxClient.new }

    context "with the real platform probe", :real_cmd do
      it "lets the first pane with an agent win its window" do
        panes = [
          pane(
            window: "win",
            command: "bash",
            pane_id: "%0"
          ),
          pane(
            window: "win",
            command: "claude",
            title: "\u{2802} project",
            pane_id: "%1"
          ),
          pane(
            window: "win",
            command: "codex",
            pane_id: "%2"
          )
        ]

        expect(
          described_class.detect_all_panes(
            client,
            panes,
            nil
          )["win"].agent
        ).to eq(:claude)
      end

      it "detects each window separately" do
        panes = [
          pane(
            window: "main",
            command: "claude",
            pane_id: "%0"
          ),
          pane(
            window: "feature",
            command: "bash",
            pane_id: "%1"
          )
        ]

        results = described_class.detect_all_panes(
          client,
          panes,
          nil
        )

        aggregate_failures do
          expect(results.length).to eq(2)
          expect(results["main"].agent).to eq(:claude)
          expect(results["feature"].agent).to be_nil
        end
      end
    end

    context "with an injected foreground job source" do
      it "forwards the source and lets the agent pane win the window" do
        panes = [
          pane(
            window: "win",
            command: "bash",
            pane_id: "%0"
          ),
          pane(
            window: "win",
            command: "claude",
            title: "\u{2802} project",
            pane_id: "%1"
          )
        ]

        results = described_class.detect_all_panes(
          client,
          panes,
          nil,
          foreground_job_source: ->(_pane_pid) {}
        )

        expect(results["win"].agent).to eq(:claude)
      end
    end
  end

  describe Orn::Detect::Platform::Linux do
    describe ".parse_tpgid" do
      it "reads the foreground pgid from a stat line" do
        expect(described_class.parse_tpgid("1234 (bash) S 1233 1234 1234 34816 5678 4194304")).to eq(5678)
      end

      it "tolerates spaces in the comm field" do
        expect(described_class.parse_tpgid("1234 (my process) S 1233 1234 1234 34816 5678 4194304")).to eq(5678)
      end

      it "tolerates parens in the comm field" do
        expect(described_class.parse_tpgid("1234 (process (v2)) S 1233 1234 1234 34816 5678 4194304")).to eq(5678)
      end

      it "returns nil for a negative tpgid (no controlling terminal)" do
        expect(described_class.parse_tpgid("1234 (bash) S 1233 1234 1234 34816 -1 4194304")).to be_nil
      end

      it "returns nil for a zero tpgid" do
        expect(described_class.parse_tpgid("1234 (bash) S 1233 1234 1234 34816 0 4194304")).to be_nil
      end

      it "returns nil for a stat line with no closing paren" do
        expect(described_class.parse_tpgid("1234 bash S 1233 1234 1234 34816 5678 4194304")).to be_nil
      end

      it "returns nil for a truncated stat line" do
        expect(described_class.parse_tpgid("1234 (bash) S 1233 1234")).to be_nil
      end
    end

    describe ".parse_pgrp_and_comm" do
      it "reads the pgrp and comm from a stat line" do
        expect(described_class.parse_pgrp_and_comm("1234 (claude) S 1233 5678 1234 34816 5678 4194304"))
          .to eq([5678, "claude"])
      end

      it "tolerates spaces in the comm field" do
        expect(described_class.parse_pgrp_and_comm("1234 (my agent) S 1233 5678 1234 34816 5678 4194304"))
          .to eq([5678, "my agent"])
      end

      it "returns nil for a stat line with no parens" do
        expect(described_class.parse_pgrp_and_comm("1234 bash S 1233 5678 1234 34816 5678 4194304")).to be_nil
      end

      it "returns nil for a truncated stat line" do
        expect(described_class.parse_pgrp_and_comm("1234 (bash) S")).to be_nil
      end

      it "returns nil for a non-numeric pgrp field" do
        expect(described_class.parse_pgrp_and_comm("1234 (bash) S 1233 xyz 1234 34816 5678 4194304")).to be_nil
      end
    end

    describe ".foreground_job" do
      # Build a fake /proc tree in a temp dir: `entries` maps each directory
      # name (usually a pid) to its files. An absent :stat or :cmdline key
      # means that file does not exist, exercising the SystemCallError rescues.
      def build_proc_root(entries)
        root = Dir.mktmpdir("orn-proc")
        proc_roots << root
        entries.each do |pid, files|
          dir = File.join(root, pid.to_s)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "stat"), files[:stat]) if files.key?(:stat)
          File.binwrite(File.join(dir, "cmdline"), files[:cmdline]) if files.key?(:cmdline)
        end
        root
      end

      def proc_roots
        @proc_roots ||= []
      end

      after do
        proc_roots.each do |root|
          FileUtils.chmod(0o700, root)
          FileUtils.remove_entry(root)
        end
      end

      # A real stat line has ~52 fields and comm may contain spaces and parens
      # (a tmux client reports as `(tmux: client)`).
      def full_stat_line(pid, comm, pgrp)
        "#{pid} (#{comm}) S 1233 #{pgrp} 5678 34816 5678 4194304 1010 0 12 0 8 4 0 0 20 0 1 0 " \
          "12345678 12345678 512 18446744073709551615 1 1 0 0 0 0 0 3670020 1266777851 1 0 0 17 " \
          "0 0 0 0 0 0 0 0 0 0 0 0 0"
      end

      it "runs against the current process without raising" do
        expect { described_class.foreground_job(Process.pid) }.not_to raise_error
      end

      it "builds the job from /proc, with nil argv for empty or unreadable cmdlines" do
        root = build_proc_root(
          1234 => {
            stat: "1234 (bash) S 1233 5678 1234 34816 5678 4194304",
            cmdline: ""
          },
          4321 => {
            stat: "4321 (vim) S 1233 5678 4321 34816 5678 4194304",
            cmdline: "vim\0notes.txt\0"
          },
          5678 => { stat: "5678 (claude) S 1233 5678 5678 34816 5678 4194304" },
          999 => {
            stat: "999 (other) S 1 999 999 34816 5678 4194304",
            cmdline: "other\0"
          },
          "self" => {}
        )

        result = described_class.foreground_job(1234, proc_root: root)

        aggregate_failures do
          expect(result.process_group_id).to eq(5678)
          expect(result.processes).to contain_exactly(
            process(1234, "bash"),
            process(
              4321,
              "vim",
              ["vim", "notes.txt"]
            ),
            process(5678, "claude")
          )
        end
      end

      it "skips a process whose stat vanishes mid-scan and a malformed stat entry" do
        root = build_proc_root(
          1234 => {
            stat: "1234 (bash) S 1233 5678 1234 34816 5678 4194304",
            cmdline: ""
          },
          777 => { cmdline: "gone\0" },
          888 => {
            stat: "not a stat line",
            cmdline: "junk\0"
          }
        )

        expect(described_class.foreground_job(1234, proc_root: root)).to eq(
          job(5678, [process(1234, "bash")])
        )
      end

      it "treats an all-NUL cmdline as nil argv and scrubs invalid UTF-8" do
        root = build_proc_root(
          1234 => {
            stat: "1234 (bash) S 1233 5678 1234 34816 5678 4194304",
            cmdline: "\0\0"
          },
          4321 => {
            stat: "4321 (vim) S 1233 5678 4321 34816 5678 4194304",
            cmdline: "vim\0\xFFnotes.txt\0".b
          }
        )

        result = described_class.foreground_job(1234, proc_root: root)

        expect(result.processes).to contain_exactly(
          process(1234, "bash"),
          process(
            4321,
            "vim",
            ["vim", "\u{FFFD}notes.txt"]
          )
        )
      end

      it "parses a full-length real stat line with parens in the comm field" do
        root = build_proc_root(
          1234 => {
            stat: full_stat_line(1234, "bash", 5678),
            cmdline: "bash\0"
          },
          5678 => {
            stat: full_stat_line(5678, "tmux: client", 5678),
            cmdline: "tmux\0attach\0"
          }
        )

        result = described_class.foreground_job(1234, proc_root: root)

        expect(result.processes).to contain_exactly(
          process(
            1234,
            "bash",
            ["bash"]
          ),
          process(
            5678,
            "tmux: client",
            %w[tmux attach]
          )
        )
      end

      it "returns nil when the pane process has no controlling terminal" do
        root = build_proc_root(
          1234 => { stat: "1234 (bash) S 1233 1234 1234 34816 -1 4194304" }
        )

        expect(described_class.foreground_job(1234, proc_root: root)).to be_nil
      end

      it "returns nil when no process belongs to the foreground group" do
        root = build_proc_root(
          1234 => { stat: "1234 (bash) S 1233 1234 1234 34816 5678 4194304" }
        )

        expect(described_class.foreground_job(1234, proc_root: root)).to be_nil
      end

      it "returns nil for a nonexistent proc root" do
        expect(described_class.foreground_job(1234, proc_root: "/nonexistent/proc-root")).to be_nil
      end

      it "returns nil when the proc root cannot be listed" do
        skip "chmod cannot revoke read access from root" if Process.uid.zero?

        root = build_proc_root(
          1234 => { stat: "1234 (bash) S 1233 5678 1234 34816 5678 4194304" }
        )
        FileUtils.chmod(0o311, root)

        expect(described_class.foreground_job(1234, proc_root: root)).to be_nil
      end
    end
  end

  describe Orn::Detect::Platform::Macos do
    def script_tpgid_query(fake, stdout: "", status: 0)
      fake.script(
        %w[ps -o tpgid= -p 1234],
        stdout: stdout,
        status: status
      )
    end

    describe ".foreground_process_group_id" do
      it "returns nil for pid 0 without running ps" do
        with_fake_cmd do |fake|
          expect(described_class.foreground_process_group_id(0)).to be_nil
          expect(fake.invocations).to be_empty
        end
      end

      it "reads the tpgid from ps output" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, stdout: "  5678\n")

          expect(described_class.foreground_process_group_id(1234)).to eq(5678)
        end
      end

      it "returns nil when ps exits nonzero" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, status: 1)

          expect(described_class.foreground_process_group_id(1234)).to be_nil
        end
      end

      it "returns nil when ps is not installed" do
        with_fake_cmd do |fake|
          fake.script_missing(%w[ps -o tpgid= -p 1234])

          expect(described_class.foreground_process_group_id(1234)).to be_nil
        end
      end

      it "returns nil when ps output is not an integer" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, stdout: "not a number\n")

          expect(described_class.foreground_process_group_id(1234)).to be_nil
        end
      end

      it "returns nil for a nonpositive tpgid (no controlling terminal)" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, stdout: "0\n")

          expect(described_class.foreground_process_group_id(1234)).to be_nil
        end
      end
    end

    describe ".foreground_job" do
      it "builds the job from the process group listing" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, stdout: "222\n")
          fake.script(
            %w[ps -o pid=,comm=,args= -g 222],
            stdout: "  222 claude /usr/bin/claude --model opus\n  223 bash\n"
          )

          expect(described_class.foreground_job(1234)).to eq(
            job(
              222,
              [
                process(
                  222,
                  "claude",
                  ["/usr/bin/claude", "--model", "opus"]
                ),
                process(223, "bash")
              ]
            )
          )
        end
      end

      it "returns nil when the tpgid lookup fails" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, status: 1)

          expect(described_class.foreground_job(1234)).to be_nil
        end
      end

      it "returns nil when the group listing fails" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, stdout: "222\n")
          fake.script(
            %w[ps -o pid=,comm=,args= -g 222],
            status: 1
          )

          expect(described_class.foreground_job(1234)).to be_nil
        end
      end

      it "returns nil when the group listing has no parseable processes" do
        with_fake_cmd do |fake|
          script_tpgid_query(fake, stdout: "222\n")
          fake.script(
            %w[ps -o pid=,comm=,args= -g 222],
            stdout: "   \n"
          )

          expect(described_class.foreground_job(1234)).to be_nil
        end
      end
    end

    describe ".parse_ps_line" do
      it "splits pid, command, and space-joined argv" do
        process = described_class.parse_ps_line("  1234 claude /usr/bin/claude --model opus")

        expect(process).to have_attributes(
          pid: 1234,
          name: "claude",
          argv: ["/usr/bin/claude", "--model", "opus"]
        )
      end

      it "returns a nil argv when only pid and command are present" do
        expect(described_class.parse_ps_line("  1234 bash")).to have_attributes(
          pid: 1234,
          name: "bash",
          argv: nil
        )
      end

      it "returns nil for an unparseable line" do
        expect(described_class.parse_ps_line("   ")).to be_nil
      end

      it "returns nil when the pid field is not a number" do
        expect(described_class.parse_ps_line("  PID COMMAND")).to be_nil
      end
    end
  end

  describe Orn::Detect::Platform, :real_cmd do
    describe ".host_os" do
      it "returns :other for an unsupported platform" do
        stub_host_os("freebsd")

        expect(described_class.host_os).to eq(:other)
      end
    end

    describe ".foreground_job" do
      it "dispatches to a platform without raising on this host" do
        expect { described_class.foreground_job(Process.pid) }.not_to raise_error
      end

      it "dispatches to the macOS implementation on darwin" do
        stub_host_os("darwin23")
        with_fake_cmd do |fake|
          fake.script(
            %w[ps -o tpgid= -p 1234],
            stdout: "222\n"
          )
          fake.script(
            %w[ps -o pid=,comm=,args= -g 222],
            stdout: "  222 claude\n"
          )

          expect(described_class.foreground_job(1234)).to eq(
            job(222, [process(222, "claude")])
          )
        end
      end

      it "returns nil on an unsupported platform" do
        stub_host_os("freebsd")

        expect(described_class.foreground_job(1234)).to be_nil
      end
    end
  end
end
