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

  describe ".container_command?" do
    it "recognizes container runtimes" do
      aggregate_failures do
        %w[docker sbx podman nerdctl].each { |name| expect(described_class.container_command?(name)).to be(true) }
      end
    end

    it "does not recognize non-container commands" do
      aggregate_failures do
        %w[bash claude node python].each { |name| expect(described_class.container_command?(name)).to be(false) }
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
    let(:mode) { Orn::OutputMode.quiet }

    it "identifies claude from the pane command" do
      result = described_class.detect_pane(
        mode,
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
        mode,
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
        mode,
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
        mode,
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
        mode,
        pane(
          window: "w",
          command: "claude",
          title: "\u{2802} project",
          pane_id: "%99"
        ),
        nil
      )

      expect(result).to have_attributes(
        agent: :claude,
        state: :working
      )
    end
  end

  describe ".detect_all_panes" do
    let(:mode) { Orn::OutputMode.quiet }

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
          mode,
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
        mode,
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
    end

    describe ".foreground_job" do
      # Fake the /proc filesystem: `stats` maps pid to stat-line content,
      # `cmdlines` maps pid to raw cmdline bytes (or an exception to raise).
      def stub_proc(stats:, cmdlines: {})
        allow(Dir).to receive(:children).and_call_original
        allow(Dir).to receive(:children).with("/proc").and_return(stats.keys.map(&:to_s) + ["self"])
        allow(File).to receive(:read).and_call_original
        stats.each do |pid, stat_line|
          allow(File).to receive(:read).with("/proc/#{pid}/stat").and_return(stat_line)
        end
        cmdlines.each do |pid, raw_cmdline|
          stub = allow(File).to receive(:binread).with("/proc/#{pid}/cmdline")
          raw_cmdline.is_a?(Class) ? stub.and_raise(raw_cmdline) : stub.and_return(raw_cmdline)
        end
      end

      it "runs against the current process without raising" do
        expect { described_class.foreground_job(Process.pid) }.not_to raise_error
      end

      it "builds the job from /proc, with nil argv for empty or unreadable cmdlines" do
        stub_proc(
          stats: {
            1234 => "1234 (bash) S 1233 5678 1234 34816 5678 4194304",
            4321 => "4321 (vim) S 1233 5678 4321 34816 5678 4194304",
            5678 => "5678 (claude) S 1233 5678 5678 34816 5678 4194304",
            999 => "999 (other) S 1 999 999 34816 5678 4194304"
          },
          cmdlines: {
            1234 => "",
            4321 => "vim\0notes.txt\0",
            5678 => Errno::EACCES
          }
        )

        expect(described_class.foreground_job(1234)).to eq(
          job(
            5678,
            [
              process(1234, "bash"),
              process(
                4321,
                "vim",
                ["vim", "notes.txt"]
              ),
              process(5678, "claude")
            ]
          )
        )
      end

      it "returns nil when /proc cannot be listed" do
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read)
          .with("/proc/1234/stat")
          .and_return("1234 (bash) S 1233 5678 1234 34816 5678 4194304")
        allow(Dir).to receive(:children).and_call_original
        allow(Dir).to receive(:children).with("/proc").and_raise(Errno::EACCES)

        expect(described_class.foreground_job(1234)).to be_nil
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

  describe Orn::Detect::Platform do
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
