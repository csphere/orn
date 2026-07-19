# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Orn::Tmux do
  let(:output_mode) { Orn::OutputMode.quiet }

  # warn_if_old_tmux remembers that it already ran; marking it done keeps the
  # version query out of the scripted command sequences.
  def with_version_check_done
    previous_state = described_class.instance_variable_get(:@version_checked)
    described_class.instance_variable_set(:@version_checked, true)
    yield
  ensure
    described_class.instance_variable_set(:@version_checked, previous_state)
  end

  # A project with the given .orn/config.yaml and a private XDG data dir, so
  # trust approvals from the machine running the suite cannot leak in.
  def open_project(config_yaml)
    ENV["XDG_DATA_HOME"] = register_temp_dir(Dir.mktmpdir("orn-open-data"))
    make_project(
      register_temp_dir(Dir.mktmpdir("orn-open")),
      config_yaml
    )
  end

  # Records the pane-command approval the way an earlier interactive run would
  # have, so the trust check passes without a prompt.
  def approve_pane_commands(project)
    approved_dir = File.join(
      ENV.fetch("XDG_DATA_HOME"),
      "orn",
      "approved"
    )
    approval_path = Orn::Trust.approval_path(approved_dir, project.root)
    commands = Orn::Trust.extract_commands(project.config.layout)
    Orn::Trust.save_approval(approval_path, Orn::Trust.commands_fingerprint(commands))
  end

  def with_stdin(reader)
    original_stdin = $stdin
    $stdin = reader
    yield
  ensure
    $stdin = original_stdin
  end

  def tty_reader(input)
    reader = StringIO.new(input)
    reader.define_singleton_method(:tty?) { true }
    reader
  end

  # Runs the block against a fake interactive terminal: stdin serves `input`
  # and claims to be a tty, stderr is captured. Returns the block result and
  # the captured prompt output.
  def with_interactive_stdin(input, &block)
    original_stderr = $stderr
    $stderr = StringIO.new
    result = with_stdin(tty_reader(input), &block)
    [result, $stderr.string]
  ensure
    $stderr = original_stderr
  end

  def has_session_argv
    ["tmux", "has-session", "-t", "proj"]
  end

  def new_window_argv(worktree_path)
    ["tmux", "new-window", "-a", "-P", "-F", "\#{pane_id}", "-t", "proj:", "-n", "feat", "-c", worktree_path]
  end

  def new_session_argv(worktree_path)
    ["tmux", "new-session", "-d", "-s", "proj", "-n", "main", "-c", worktree_path]
  end

  def split_argv(worktree_path)
    ["tmux", "split-window", "-h", "-t", "%0", "-c", worktree_path, "-l", "50%", "-P", "-F", "\#{pane_id}"]
  end

  # Scripts the tmux calls that open a "feat" window holding a single pane
  # (%0) running "echo hi" in an existing "proj" session.
  def script_command_window(fake, worktree_path)
    fake.script(has_session_argv)
    fake.script(new_window_argv(worktree_path), stdout: "%0\n")
    fake.script(["tmux", "run-shell", "-b", "-d", "10", "tmux wait-for -S orn-ready-0"])
    fake.script(["tmux", "send-keys", "-t", "%0", described_class.shell_ready_command("orn-ready-0"), "Enter"])
    fake.script(%w[tmux wait-for orn-ready-0])
    fake.script(["tmux", "send-keys", "-t", "%0", "echo hi", "Enter"])
    fake.script(["tmux", "select-pane", "-t", "%0"])
    fake.script(["tmux", "select-window", "-t", "proj:feat"])
  end

  describe ".open_window_with_layout" do
    let(:command_layout) do
      Orn::Config::Layout.of_columns([Orn::Config::Column.new(panes: ["echo hi"])])
    end

    it "prompts for trust, runs the approved commands, and returns the branch and session" do
      project = open_project("tmux:\n  session: proj\n")

      with_fake_cmd do |fake|
        script_command_window(fake, project.worktree_path("feat"))

        result, prompt_output = with_version_check_done do
          with_interactive_stdin("y\n") do
            described_class.open_window_with_layout(
              output_mode,
              project,
              "feat",
              command_layout,
              :project
            )
          end
        end

        aggregate_failures do
          expect(result).to eq(
            described_class::OpenWindowResult.new(
              branch: "feat",
              session: "proj"
            )
          )
          expect(prompt_output).to include("Trust these commands? [y/N]")
          expect(fake.invocations).to include(["tmux", "send-keys", "-t", "%0", "echo hi", "Enter"])
        end
      end
    end
  end

  describe ".open_window_non_interactive" do
    let(:command_config_yaml) do
      <<~YAML
        tmux:
          session: proj
          columns:
            - panes: ["echo hi"]
      YAML
    end

    it "raises for untrusted project pane commands instead of prompting, even at a tty" do
      project = open_project(command_config_yaml)

      with_fake_cmd do |fake|
        with_interactive_stdin("y\n") do
          expect do
            described_class.open_window_non_interactive(
              output_mode,
              project,
              "feat"
            )
          end
            .to raise_error(Orn::Error, /untrusted pane commands/)
        end

        expect(fake.invocations).to be_empty
      end
    end

    it "opens the window without a prompt once the commands are approved" do
      project = open_project(command_config_yaml)
      approve_pane_commands(project)

      with_fake_cmd do |fake|
        script_command_window(fake, project.worktree_path("feat"))

        result = with_version_check_done do
          with_stdin(StringIO.new("")) do
            described_class.open_window_non_interactive(
              output_mode,
              project,
              "feat"
            )
          end
        end

        aggregate_failures do
          expect(result).to have_attributes(
            branch: "feat",
            session: "proj"
          )
          expect(fake.invocations).to include(["tmux", "send-keys", "-t", "%0", "echo hi", "Enter"])
        end
      end
    end
  end

  describe ".open_window" do
    it "creates the window in the configured session at the worktree path, seeding with the base window" do
      project = open_project("git:\n  base: main\ntmux:\n  session: proj\n")
      worktree_path = project.worktree_path("feat")

      with_fake_cmd do |fake|
        fake.script(has_session_argv, status: 1)
        fake.script(new_session_argv(worktree_path))
        fake.script(new_window_argv(worktree_path), stdout: "%0\n")
        fake.script(split_argv(worktree_path), stdout: "%1\n")
        fake.script(["tmux", "select-pane", "-t", "%0"])
        fake.script(["tmux", "select-window", "-t", "proj:feat"])

        result = with_version_check_done { described_class.open_window(output_mode, project, "feat") }

        aggregate_failures do
          expect(result).to have_attributes(
            branch: "feat",
            session: "proj"
          )
          expect(fake.invocations).to eq(
            [
              has_session_argv,
              has_session_argv,
              new_session_argv(worktree_path),
              new_window_argv(worktree_path),
              split_argv(worktree_path),
              ["tmux", "select-pane", "-t", "%0"],
              ["tmux", "select-window", "-t", "proj:feat"]
            ]
          )
        end
      end
    end
  end
end
