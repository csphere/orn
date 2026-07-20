# frozen_string_literal: true

# Pure helpers on the Orn::Tmux module. Everything that shells out to tmux is
# a client verb, pinned in spec/orn/tmux/client_spec.rb.
RSpec.describe Orn::Tmux do
  # warn_if_old_tmux remembers that it already ran (@version_checked), and other
  # examples in the process may have tripped it. Each example sets the state it
  # needs and puts back whatever was there before.
  def with_version_check_state(checked)
    previous_state = described_class.instance_variable_get(:@version_checked)
    described_class.instance_variable_set(:@version_checked, checked)
    yield
  ensure
    described_class.instance_variable_set(:@version_checked, previous_state)
  end

  describe ".window_target" do
    it "joins session and window with a colon" do
      expect(described_class.window_target("work", "feature")).to eq("work:feature")
    end
  end

  describe ".shell_ready_command" do
    it "clears the screen and history before the ready signal, which comes last" do
      parts = described_class.shell_ready_command("orn-ready-42").split(";").map(&:strip)
      signal_index = parts.index { |part| part.include?("wait-for -S") }
      clear_index = parts.index("clear")
      history_index = parts.index { |part| part.include?("clear-history") }

      aggregate_failures do
        expect(clear_index).to be < signal_index
        expect(history_index).to be < signal_index
        expect(signal_index).to eq(parts.length - 1)
      end
    end
  end

  describe ".window_guard_condition" do
    it "builds a tmux condition matching only the given session and window" do
      condition = described_class.window_guard_condition("dev", "orn")

      expect(condition).to eq('#{&&:#{==:#{session_name},dev},#{==:#{window_name},orn}}')
    end
  end

  describe ".parse_pane_lines" do
    it "parses one metadata record per line" do
      output = "main\t12345\tclaude\t%0\tClaude Code\nfeature\t67890\tbash\t%1\t~/project\n"

      panes = described_class.parse_pane_lines(output, with_session: false)

      aggregate_failures do
        expect(panes.length).to eq(2)
        expect(panes[0]).to have_attributes(
          window_name: "main",
          pane_pid: 12_345,
          pane_current_command: "claude",
          pane_id: "%0",
          pane_title: "Claude Code",
          session_name: nil
        )
        expect(panes[1]).to have_attributes(
          window_name: "feature",
          pane_pid: 67_890,
          pane_current_command: "bash"
        )
      end
    end

    it "skips lines with the wrong field count" do
      output = "valid\t123\tcmd\t%0\ttitle\nonly\ttwo\nvalid\t456\tcmd2\t%1\ttitle2\n"

      panes = described_class.parse_pane_lines(output, with_session: false)

      expect(panes.map(&:pane_pid)).to eq([123, 456])
    end

    it "skips lines whose pid is not a number" do
      panes = described_class.parse_pane_lines("win\tnot_a_number\tcmd\t%0\ttitle\n", with_session: false)

      expect(panes).to be_empty
    end

    it "includes the session name for the all-sessions listing" do
      panes = described_class.parse_pane_lines("sess\tmain\t12345\tclaude\t%0\tTitle\n", with_session: true)

      expect(panes.first).to have_attributes(
        session_name: "sess",
        window_name: "main",
        pane_pid: 12_345,
        pane_title: "Title",
        pane_current_command: "claude",
        pane_id: "%0"
      )
    end

    it "keeps embedded tabs in the trailing title field" do
      panes = described_class.parse_pane_lines("sess\tmain\t12345\tclaude\t%0\tTitle\twith\ttabs\n", with_session: true)

      expect(panes.first).to have_attributes(
        pane_title: "Title\twith\ttabs",
        pane_id: "%0"
      )
    end

    it "returns nothing for empty input" do
      expect(described_class.parse_pane_lines("", with_session: false)).to be_empty
    end

    it "rejects an all-sessions line missing the session field" do
      panes = described_class.parse_pane_lines("main\t12345\tcmd\t%0\n", with_session: true)

      expect(panes).to be_empty
    end
  end

  describe ".parse_borrowed_lines" do
    it "keeps only panes with both home tags set" do
      output = "%0\t\t\n%3\tdev\tissues/270\n%5\tother\t\n"

      borrowed = described_class.parse_borrowed_lines(output)

      expect(borrowed).to eq(
        [
          described_class::BorrowedPane.new(
            pane_id: "%3",
            home_session: "dev",
            home_window: "issues/270"
          )
        ]
      )
    end

    it "ignores lines without all three fields" do
      expect(described_class.parse_borrowed_lines("%1\n%2\tonly-one-field\n")).to be_empty
    end
  end

  describe ".warn_if_old_tmux" do
    def version_check_argv
      ["tmux", "-V"]
    end

    it "warns when tmux is older than 2.9" do
      with_fake_cmd do |fake|
        fake.script(version_check_argv, stdout: "tmux 2.8\n")

        with_version_check_state(nil) do
          expect { described_class.warn_if_old_tmux }.to output(/tmux 2\.9\+ required \(found 2\.8\)/).to_stderr
        end
      end
    end

    ["tmux 2.9", "tmux 3.4"].each do |version_line|
      it "does not warn for #{version_line}" do
        with_fake_cmd do |fake|
          fake.script(version_check_argv, stdout: "#{version_line}\n")

          with_version_check_state(nil) do
            expect { described_class.warn_if_old_tmux }.not_to output.to_stderr
          end
        end
      end
    end

    it "stays quiet when the version is not a number" do
      with_fake_cmd do |fake|
        fake.script(version_check_argv, stdout: "tmux next-3.5\n")

        with_version_check_state(nil) do
          expect { described_class.warn_if_old_tmux }.not_to output.to_stderr
        end
      end
    end

    it "stays quiet when the output is not a tmux version line" do
      with_fake_cmd do |fake|
        fake.script(version_check_argv, stdout: "openbsd 7.4\n")

        with_version_check_state(nil) do
          expect { described_class.warn_if_old_tmux }.not_to output.to_stderr
        end
      end
    end

    it "stays quiet when the version query fails" do
      with_fake_cmd do |fake|
        fake.script(version_check_argv, status: 1)

        with_version_check_state(nil) do
          expect { described_class.warn_if_old_tmux }.not_to output.to_stderr
        end
      end
    end

    it "stays quiet when tmux is not installed" do
      with_fake_cmd do |fake|
        fake.script_missing(version_check_argv)

        with_version_check_state(nil) do
          expect { described_class.warn_if_old_tmux }.not_to output.to_stderr
        end
      end
    end

    it "checks the version only once per process" do
      with_fake_cmd do |fake|
        fake.script(version_check_argv, stdout: "tmux 3.4\n")

        with_version_check_state(nil) do
          described_class.warn_if_old_tmux
          described_class.warn_if_old_tmux
        end

        expect(fake.invocations).to eq([version_check_argv])
      end
    end
  end
end
