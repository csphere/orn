# frozen_string_literal: true

require "stringio"
require "tmpdir"

# The adapter spec: the one place the domain-verb to tmux-argv translation is
# pinned. Every scripted argv literal here is the contract the rest of the
# suite relies on through FakeTmuxClient.
RSpec.describe Orn::Tmux::Client do
  let(:output_mode) { Orn::OutputMode.quiet }
  let(:client) { described_class.new(output_mode: output_mode) }

  # warn_if_old_tmux remembers that it already ran (@version_checked), and
  # other examples in the process may have tripped it. Each example sets the
  # state it needs and puts back whatever was there before.
  def with_version_check_state(checked)
    previous_state = Orn::Tmux.instance_variable_get(:@version_checked)
    Orn::Tmux.instance_variable_set(:@version_checked, checked)
    yield
  ensure
    Orn::Tmux.instance_variable_set(:@version_checked, previous_state)
  end

  def has_session_argv(session)
    ["tmux", "has-session", "-t", session]
  end

  def list_windows_argv(session)
    ["tmux", "list-windows", "-t", "#{session}:", "-F", "\#{window_name}"]
  end

  def new_window_argv(session, window, path)
    ["tmux", "new-window", "-a", "-P", "-F", "\#{pane_id}", "-t", "#{session}:", "-n", window, "-c", path]
  end

  describe "#ensure_session" do
    it "does nothing when the session already exists" do
      with_fake_cmd do |fake|
        fake.script(has_session_argv("work"))

        client.ensure_session("work", "/tmp/repo")

        expect(fake.invocations).to eq([has_session_argv("work")])
      end
    end

    it "creates the session detached with a seed window name and path" do
      with_fake_cmd do |fake|
        create_argv = ["tmux", "new-session", "-d", "-s", "work", "-n", "main", "-c", "/tmp/repo"]
        fake.script(has_session_argv("work"), status: 1)
        fake.script(create_argv)

        client.ensure_session(
          "work",
          "/tmp/repo",
          "main"
        )

        expect(fake.invocations).to eq([has_session_argv("work"), create_argv])
      end
    end

    it "omits the window name when none is given" do
      with_fake_cmd do |fake|
        create_argv = ["tmux", "new-session", "-d", "-s", "work", "-c", "/tmp/repo"]
        fake.script(has_session_argv("work"), status: 1)
        fake.script(create_argv)

        client.ensure_session("work", "/tmp/repo")

        expect(fake.invocations).to eq([has_session_argv("work"), create_argv])
      end
    end
  end

  describe "#session_exists?" do
    it "reports an existing session" do
      with_fake_cmd do |fake|
        fake.script(has_session_argv("work"))

        expect(client.session_exists?("work")).to be(true)
      end
    end

    it "reports a missing session" do
      with_fake_cmd do |fake|
        fake.script(has_session_argv("absent"), status: 1)

        expect(client.session_exists?("absent")).to be(false)
      end
    end

    it "reports the session absent when tmux is not installed" do
      with_fake_cmd do |fake|
        fake.script_missing(has_session_argv("work"))

        expect(client.session_exists?("work")).to be(false)
      end
    end
  end

  describe "#client_session" do
    def client_session_argv
      ["tmux", "display-message", "-p", "\#{client_session}"]
    end

    it "returns nil when not inside tmux" do
      ENV.delete("TMUX")

      with_fake_cmd do |fake|
        expect(client.client_session).to be_nil
        expect(fake.invocations).to be_empty
      end
    end

    it "returns the attached client's session name" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script(client_session_argv, stdout: "work\n")

        expect(client.client_session).to eq("work")
      end
    end

    it "returns nil when tmux reports an empty session name" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script(client_session_argv, stdout: "\n")

        expect(client.client_session).to be_nil
      end
    end

    it "returns nil when the tmux query fails" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script(client_session_argv, status: 1)

        expect(client.client_session).to be_nil
      end
    end

    it "returns nil when tmux is not installed" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script_missing(client_session_argv)

        expect(client.client_session).to be_nil
      end
    end
  end

  describe "#session_path" do
    def session_path_argv(session)
      ["tmux", "display-message", "-t", "#{session}:", "-p", "\#{session_path}"]
    end

    it "returns the canonicalized path of the session" do
      dir = register_temp_dir(Dir.mktmpdir("orn-session-path"))

      with_fake_cmd do |fake|
        fake.script(session_path_argv("work"), stdout: "#{dir}\n")

        expect(client.session_path("work")).to eq(File.realpath(dir))
      end
    end

    it "returns nil when the query fails" do
      with_fake_cmd do |fake|
        fake.script(session_path_argv("work"), status: 1)

        expect(client.session_path("work")).to be_nil
      end
    end

    it "returns nil when tmux is not installed" do
      with_fake_cmd do |fake|
        fake.script_missing(session_path_argv("work"))

        expect(client.session_path("work")).to be_nil
      end
    end

    it "returns nil when tmux reports an empty path" do
      with_fake_cmd do |fake|
        fake.script(session_path_argv("work"), stdout: "\n")

        expect(client.session_path("work")).to be_nil
      end
    end

    it "returns nil when the reported path does not exist on disk" do
      with_fake_cmd do |fake|
        fake.script(session_path_argv("work"), stdout: "/nonexistent/orn-elsewhere\n")

        expect(client.session_path("work")).to be_nil
      end
    end
  end

  describe "#list_sessions" do
    def list_sessions_argv
      ["tmux", "list-sessions", "-F", "\#{session_name}\t\#{session_activity}"]
    end

    it "returns each session's name and activity time" do
      with_fake_cmd do |fake|
        fake.script(list_sessions_argv, stdout: "work\t1700000000\nplay\t1700000005\n")

        expect(client.list_sessions).to eq(
          [
            Orn::Tmux::SessionInfo.new(
              name: "work",
              activity: 1_700_000_000
            ),
            Orn::Tmux::SessionInfo.new(
              name: "play",
              activity: 1_700_000_005
            )
          ]
        )
      end
    end

    it "skips lines without an activity field" do
      with_fake_cmd do |fake|
        fake.script(list_sessions_argv, stdout: "malformed\nwork\t1700000000\n")

        expect(client.list_sessions.map(&:name)).to eq(["work"])
      end
    end

    it "returns no sessions when the listing fails" do
      with_fake_cmd do |fake|
        fake.script(
          list_sessions_argv,
          stderr: "no server running",
          status: 1
        )

        expect(client.list_sessions).to eq([])
      end
    end

    it "returns no sessions when tmux is not installed" do
      with_fake_cmd do |fake|
        fake.script_missing(list_sessions_argv)

        expect(client.list_sessions).to eq([])
      end
    end
  end

  describe "#switch_client" do
    it "switches the attached client to the window" do
      with_fake_cmd do |fake|
        argv = ["tmux", "switch-client", "-t", "work:orn"]
        fake.script(argv)

        client.switch_client("work", "orn")

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#create_window" do
    # One row holding a single pane whose command carries a template variable.
    let(:templated_layout) do
      Orn::Config::Layout.of_rows(
        [
          Orn::Config::Row.new(
            panes: ["echo {{branch}}"],
            columns: []
          )
        ]
      )
    end
    let(:empty_layout) { Orn::Config::Layout.of_columns([]) }

    it "substitutes template variables into pane commands after waiting for the shell" do
      ready_command = Orn::Tmux.shell_ready_command("orn-ready-7")

      with_fake_cmd do |fake|
        fake.script(has_session_argv("work"))
        fake.script(new_window_argv("work", "feat", "/tmp/repo"), stdout: "%7\n")
        fake.script(["tmux", "run-shell", "-b", "-d", "10", "tmux wait-for -S orn-ready-7"])
        fake.script(["tmux", "send-keys", "-t", "%7", ready_command, "Enter"])
        fake.script(%w[tmux wait-for orn-ready-7])
        fake.script(["tmux", "send-keys", "-t", "%7", "echo feat", "Enter"])
        fake.script(["tmux", "select-pane", "-t", "%7"])
        fake.script(["tmux", "select-window", "-t", "work:feat"])

        with_version_check_state(true) do
          client.create_window(
            "work",
            "feat",
            "/tmp/repo",
            templated_layout,
            template_vars: { "branch" => "feat" }
          )
        end

        expect(fake.invocations).to eq(
          [
            has_session_argv("work"),
            has_session_argv("work"),
            new_window_argv("work", "feat", "/tmp/repo"),
            ["tmux", "run-shell", "-b", "-d", "10", "tmux wait-for -S orn-ready-7"],
            ["tmux", "send-keys", "-t", "%7", ready_command, "Enter"],
            %w[tmux wait-for orn-ready-7],
            ["tmux", "send-keys", "-t", "%7", "echo feat", "Enter"],
            ["tmux", "select-pane", "-t", "%7"],
            ["tmux", "select-window", "-t", "work:feat"]
          ]
        )
      end
    end

    def script_unsupported_run_shell(fake)
      fake.script(has_session_argv("work"))
      fake.script(new_window_argv("work", "feat", "/tmp/repo"), stdout: "%7\n")
      fake.script(
        ["tmux", "run-shell", "-b", "-d", "10", "tmux wait-for -S orn-ready-7"],
        stderr: "usage: run-shell [-b] shell-command",
        status: 1
      )
      fake.script(["tmux", "send-keys", "-t", "%7", Orn::Tmux.shell_ready_command("orn-ready-7"), "Enter"])
      fake.script(["tmux", "send-keys", "-t", "%7", "echo feat", "Enter"])
      fake.script(["tmux", "select-pane", "-t", "%7"])
      fake.script(["tmux", "select-window", "-t", "work:feat"])
    end

    it "skips the shell wait when run-shell -d is unsupported (tmux < 3.2)" do
      with_fake_cmd do |fake|
        script_unsupported_run_shell(fake)

        with_version_check_state(true) do
          client.create_window(
            "work",
            "feat",
            "/tmp/repo",
            templated_layout,
            template_vars: { "branch" => "feat" }
          )
        end

        aggregate_failures do
          expect(fake.invocations).to include(["tmux", "send-keys", "-t", "%7", "echo feat", "Enter"])
          expect(fake.invocations).not_to include(%w[tmux wait-for orn-ready-7])
        end
      end
    end

    it "creates the window and selects it without splitting when the layout is empty" do
      with_fake_cmd do |fake|
        fake.script(has_session_argv("work"))
        fake.script(new_window_argv("work", "feat", "/tmp/repo"), stdout: "%3\n")
        fake.script(["tmux", "select-window", "-t", "work:feat"])

        with_version_check_state(true) do
          client.create_window(
            "work",
            "feat",
            "/tmp/repo",
            empty_layout
          )
        end

        expect(fake.invocations).to eq(
          [
            has_session_argv("work"),
            has_session_argv("work"),
            new_window_argv("work", "feat", "/tmp/repo"),
            ["tmux", "select-window", "-t", "work:feat"]
          ]
        )
      end
    end
  end

  describe "#new_window_running" do
    it "adds a window running the command without selecting it" do
      with_fake_cmd do |fake|
        argv = ["tmux", "new-window", "-a", "-t", "work:", "-n", "orn", "-c", "/tmp/repo", "ORN_TUI=1 exec orn"]
        fake.script(argv)

        client.new_window_running(
          "work",
          "orn",
          "/tmp/repo",
          "ORN_TUI=1 exec orn"
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#send_keys" do
    it "types the keys followed by Enter" do
      with_fake_cmd do |fake|
        argv = ["tmux", "send-keys", "-t", "%5", "echo hi", "Enter"]
        fake.script(argv)

        client.send_keys("%5", "echo hi")

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#window_exists?" do
    it "reports whether the window is listed in the session" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("work"), stdout: "main\nfeat\n")

        aggregate_failures do
          expect(client.window_exists?("work", "feat")).to be(true)
          expect(client.window_exists?("work", "gone")).to be(false)
        end
      end
    end
  end

  describe "#pane_command" do
    def pane_command_argv(session, window)
      ["tmux", "list-panes", "-t", "#{session}:#{window}", "-F", "\#{pane_current_command}"]
    end

    it "returns the command of the window's first pane" do
      with_fake_cmd do |fake|
        fake.script(pane_command_argv("work", "feat"), stdout: "vim\nzsh\n")

        expect(client.pane_command("work", "feat")).to eq("vim")
      end
    end

    it "returns nil when the window does not exist" do
      with_fake_cmd do |fake|
        fake.script(pane_command_argv("work", "gone"), status: 1)

        expect(client.pane_command("work", "gone")).to be_nil
      end
    end

    it "returns nil when tmux is not installed" do
      with_fake_cmd do |fake|
        fake.script_missing(pane_command_argv("work", "feat"))

        expect(client.pane_command("work", "feat")).to be_nil
      end
    end

    it "returns nil when tmux reports no panes" do
      with_fake_cmd do |fake|
        fake.script(pane_command_argv("work", "feat"), stdout: "")

        expect(client.pane_command("work", "feat")).to be_nil
      end
    end
  end

  describe "#select_window" do
    it "selects the window by session-qualified target" do
      with_fake_cmd do |fake|
        argv = ["tmux", "select-window", "-t", "work:feat"]
        fake.script(argv)

        client.select_window("work", "feat")

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#kill_window" do
    it "kills the window by session-qualified target" do
      with_fake_cmd do |fake|
        argv = ["tmux", "kill-window", "-t", "work:feat"]
        fake.script(argv)

        client.kill_window("work", "feat")

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#list_windows" do
    it "returns the window names of the session" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("work"), stdout: "main\nfeat\n")

        expect(client.list_windows("work")).to eq(%w[main feat])
      end
    end

    it "returns no windows when the session does not exist" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("absent"), status: 1)

        expect(client.list_windows("absent")).to eq([])
      end
    end

    it "returns no windows when tmux is not installed" do
      with_fake_cmd do |fake|
        fake.script_missing(list_windows_argv("work"))

        expect(client.list_windows("work")).to eq([])
      end
    end
  end

  describe "#reorder_windows" do
    def swap_argv(src, dst)
      ["tmux", "swap-window", "-d", "-s", src, "-t", dst]
    end

    it "swaps the TUI window to the front, ahead of the base branch" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("work"), stdout: "main\norn\n")
        fake.script(swap_argv("work:main", "work:orn"))

        client.reorder_windows("work", "main")

        expect(fake.invocations).to eq(
          [
            list_windows_argv("work"),
            swap_argv("work:main", "work:orn")
          ]
        )
      end
    end

    it "swaps repeatedly, tracking positions, until worktrees are sorted after orn and the base" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("work"), stdout: "b\na\norn\nmain\n")
        fake.script(swap_argv("work:b", "work:orn"))
        fake.script(swap_argv("work:a", "work:main"))
        fake.script(swap_argv("work:b", "work:a"))

        client.reorder_windows("work", "main")

        expect(fake.invocations).to eq(
          [
            list_windows_argv("work"),
            swap_argv("work:b", "work:orn"),
            swap_argv("work:a", "work:main"),
            swap_argv("work:b", "work:a")
          ]
        )
      end
    end

    it "swaps nothing when the order is already correct" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("work"), stdout: "orn\nmain\nfeat\n")

        client.reorder_windows("work", "main")

        expect(fake.invocations).to eq([list_windows_argv("work")])
      end
    end

    it "does nothing for a single window" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("work"), stdout: "main\n")

        client.reorder_windows("work", "main")

        expect(fake.invocations).to eq([list_windows_argv("work")])
      end
    end

    it "does nothing when the window listing fails" do
      with_fake_cmd do |fake|
        fake.script(list_windows_argv("gone"), status: 1)

        client.reorder_windows("gone", "main")

        expect(fake.invocations).to eq([list_windows_argv("gone")])
      end
    end
  end

  describe "#list_panes_metadata" do
    def list_panes_argv(session)
      ["tmux", "list-panes", "-s", "-t", "#{session}:", "-F", Orn::Tmux::PANE_FORMAT]
    end

    it "returns metadata for every pane in the session" do
      with_fake_cmd do |fake|
        fake.script(list_panes_argv("work"), stdout: "main\t12345\tclaude\t%0\tClaude Code\n")

        panes = client.list_panes_metadata("work")

        expect(panes).to contain_exactly(
          have_attributes(
            session_name: nil,
            window_name: "main",
            pane_pid: 12_345,
            pane_current_command: "claude",
            pane_id: "%0",
            pane_title: "Claude Code"
          )
        )
      end
    end

    it "returns no panes when the listing fails" do
      with_fake_cmd do |fake|
        fake.script(list_panes_argv("work"), status: 1)

        expect(client.list_panes_metadata("work")).to eq([])
      end
    end
  end

  describe "#list_all_panes_metadata" do
    def all_panes_argv
      ["tmux", "list-panes", "-a", "-F", Orn::Tmux::PANE_FORMAT_ALL]
    end

    it "returns metadata for every pane on the server, tagged with its session" do
      with_fake_cmd do |fake|
        fake.script(all_panes_argv, stdout: "sess\tmain\t12345\tclaude\t%0\tTitle\n")

        panes = client.list_all_panes_metadata

        expect(panes).to contain_exactly(
          have_attributes(
            session_name: "sess",
            window_name: "main",
            pane_id: "%0"
          )
        )
      end
    end

    it "returns nil when the listing fails, not an empty list" do
      with_fake_cmd do |fake|
        fake.script(
          all_panes_argv,
          stderr: "no server running",
          status: 1
        )

        expect(client.list_all_panes_metadata).to be_nil
      end
    end
  end

  describe "#capture_pane" do
    def capture_argv(pane)
      ["tmux", "capture-pane", "-p", "-t", pane]
    end

    it "returns the pane's visible contents" do
      with_fake_cmd do |fake|
        fake.script(capture_argv("%5"), stdout: "hello\n")

        expect(client.capture_pane("%5")).to eq("hello\n")
      end
    end

    it "returns nil when the capture fails" do
      with_fake_cmd do |fake|
        fake.script(capture_argv("%5"), status: 1)

        expect(client.capture_pane("%5")).to be_nil
      end
    end
  end

  describe "#join_pane" do
    it "joins the pane as a horizontal split with the given width" do
      with_fake_cmd do |fake|
        argv = ["tmux", "join-pane", "-h", "-s", "%5", "-t", "hub:tabs", "-l", "40%"]
        fake.script(argv)

        client.join_pane(
          "%5",
          "hub:tabs",
          40,
          true
        )

        expect(fake.invocations).to eq([argv])
      end
    end

    it "detaches the join when focus is false" do
      with_fake_cmd do |fake|
        argv = ["tmux", "join-pane", "-h", "-d", "-s", "%5", "-t", "hub:tabs", "-l", "40%"]
        fake.script(argv)

        client.join_pane(
          "%5",
          "hub:tabs",
          40,
          false
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#break_pane" do
    it "targets the session with a trailing colon" do
      with_fake_cmd do |fake|
        argv = ["tmux", "break-pane", "-d", "-s", "%5", "-n", "editor", "-t", "home:"]
        fake.script(argv)

        client.break_pane(
          "%5",
          "home",
          "editor"
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#recreate_session_with_pane" do
    let(:cwd_argv) { ["tmux", "display-message", "-p", "-t", "%5", "\#{pane_current_path}"] }

    it "creates a placeholder session, moves the pane in, and kills the placeholder" do
      with_fake_cmd do |fake|
        new_session_argv = [
          "tmux",
          "new-session",
          "-d",
          "-s",
          "home",
          "-c",
          "/proj",
          "-P",
          "-F",
          "\#{window_id}"
        ]
        break_argv = ["tmux", "break-pane", "-d", "-s", "%5", "-n", "editor", "-t", "home:"]
        kill_argv = ["tmux", "kill-window", "-t", "@9"]
        fake.script(cwd_argv, stdout: "/proj\n")
        fake.script(new_session_argv, stdout: "@9\n")
        fake.script(break_argv)
        fake.script(kill_argv)

        client.recreate_session_with_pane(
          "%5",
          "home",
          "editor"
        )

        expect(fake.invocations).to eq(
          [
            cwd_argv,
            new_session_argv,
            break_argv,
            kill_argv
          ]
        )
      end
    end

    it "raises when the pane's cwd cannot be determined" do
      with_fake_cmd do |fake|
        fake.script(cwd_argv, stdout: "\n")

        expect do
          client.recreate_session_with_pane(
            "%5",
            "home",
            "editor"
          )
        end
          .to raise_error(Orn::Error, /cannot determine cwd/)
      end
    end
  end

  describe "#select_pane" do
    it "makes the pane active" do
      with_fake_cmd do |fake|
        argv = ["tmux", "select-pane", "-t", "%5"]
        fake.script(argv)

        client.select_pane("%5")

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#resize_pane_width" do
    it "resizes the pane to a percentage of the window width" do
      with_fake_cmd do |fake|
        argv = ["tmux", "resize-pane", "-t", "%5", "-x", "33%"]
        fake.script(argv)

        client.resize_pane_width("%5", 33)

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#set_pane_option" do
    it "sets a pane-scoped user option" do
      with_fake_cmd do |fake|
        argv = ["tmux", "set-option", "-p", "-t", "%5", "@orn_home_session", "home"]
        fake.script(argv)

        client.set_pane_option(
          "%5",
          Orn::Tmux::OPT_HOME_SESSION,
          "home"
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#unset_pane_option" do
    it "unsets a pane-scoped user option" do
      with_fake_cmd do |fake|
        argv = ["tmux", "set-option", "-p", "-u", "-t", "%5", "@orn_home_window"]
        fake.script(argv)

        client.unset_pane_option("%5", Orn::Tmux::OPT_HOME_WINDOW)

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#list_borrowed_panes" do
    let(:list_argv) do
      [
        "tmux",
        "list-panes",
        "-a",
        "-F",
        "\#{pane_id}\t\#{@orn_home_session}\t\#{@orn_home_window}"
      ]
    end

    it "returns only panes tagged with a home session and window" do
      with_fake_cmd do |fake|
        fake.script(list_argv, stdout: "%1\thome\teditor\n%2\t\t\n")

        panes = client.list_borrowed_panes

        expect(panes).to contain_exactly(
          Orn::Tmux::BorrowedPane.new(
            pane_id: "%1",
            home_session: "home",
            home_window: "editor"
          )
        )
      end
    end

    it "returns no panes when tmux fails" do
      with_fake_cmd do |fake|
        fake.script(
          list_argv,
          stderr: "no server running",
          status: 1
        )

        expect(client.list_borrowed_panes).to eq([])
      end
    end
  end

  describe "#active_pane" do
    let(:panes_argv) do
      [
        "tmux",
        "list-panes",
        "-t",
        "hub:tabs",
        "-F",
        "\#{pane_id}\t\#{?pane_active,1,0}"
      ]
    end

    it "returns the id of the active pane in the window" do
      with_fake_cmd do |fake|
        fake.script(panes_argv, stdout: "%1\t0\n%2\t1\n")

        expect(client.active_pane("hub", "tabs")).to eq("%2")
      end
    end

    it "returns nothing when the window does not exist" do
      with_fake_cmd do |fake|
        fake.script(
          panes_argv,
          stderr: "can't find window",
          status: 1
        )

        expect(client.active_pane("hub", "tabs")).to be_nil
      end
    end
  end

  describe "#current_session_window" do
    let(:display_argv) { ["tmux", "display-message", "-p", "-t", "%5", "\#{session_name}\t\#{window_name}"] }

    it "returns the session and window containing the pane" do
      with_fake_cmd do |fake|
        fake.script(display_argv, stdout: "home\teditor\n")

        expect(client.current_session_window("%5")).to eq(%w[home editor])
      end
    end

    it "returns nothing when the pane does not exist" do
      with_fake_cmd do |fake|
        fake.script(
          display_argv,
          stderr: "can't find pane",
          status: 1
        )

        expect(client.current_session_window("%5")).to be_nil
      end
    end
  end

  describe "#bind_key_guarded" do
    it "binds through if-shell with a send-keys fallthrough" do
      with_fake_cmd do |fake|
        condition = Orn::Tmux.window_guard_condition("hub", "tabs")
        argv = [
          "tmux",
          "bind-key",
          "-n",
          "F1",
          "if-shell",
          "-F",
          condition,
          "select-window -t hub:tabs",
          "send-keys F1"
        ]
        fake.script(argv)

        client.bind_key_guarded(
          "F1",
          condition,
          "select-window -t hub:tabs"
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "#unbind_key" do
    it "removes a root-table binding" do
      with_fake_cmd do |fake|
        argv = ["tmux", "unbind-key", "-n", "F1"]
        fake.script(argv)

        client.unbind_key("F1")

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe "window opening" do
    # A project with the given .orn/config.yaml and a private XDG data dir, so
    # trust approvals from the machine running the suite cannot leak in.
    def open_project(config_yaml)
      ENV["XDG_DATA_HOME"] = register_temp_dir(Dir.mktmpdir("orn-open-data"))
      make_project(
        register_temp_dir(Dir.mktmpdir("orn-open")),
        config_yaml
      )
    end

    # Records the pane-command approval the way an earlier interactive run
    # would have, so the trust check passes without a prompt.
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

    def proj_has_session_argv
      has_session_argv("proj")
    end

    def proj_new_window_argv(worktree_path)
      new_window_argv("proj", "feat", worktree_path)
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
      fake.script(proj_has_session_argv)
      fake.script(proj_new_window_argv(worktree_path), stdout: "%0\n")
      fake.script(["tmux", "run-shell", "-b", "-d", "10", "tmux wait-for -S orn-ready-0"])
      fake.script(["tmux", "send-keys", "-t", "%0", Orn::Tmux.shell_ready_command("orn-ready-0"), "Enter"])
      fake.script(%w[tmux wait-for orn-ready-0])
      fake.script(["tmux", "send-keys", "-t", "%0", "echo hi", "Enter"])
      fake.script(["tmux", "select-pane", "-t", "%0"])
      fake.script(["tmux", "select-window", "-t", "proj:feat"])
    end

    describe "#open_window_with_layout" do
      let(:command_layout) do
        Orn::Config::Layout.of_columns([Orn::Config::Column.new(panes: ["echo hi"])])
      end

      it "prompts for trust, runs the approved commands, and returns the branch and session" do
        project = open_project("tmux:\n  session: proj\n")

        with_fake_cmd do |fake|
          script_command_window(fake, project.worktree_path("feat"))

          result, prompt_output = with_version_check_state(true) do
            with_interactive_stdin("y\n") do
              client.open_window_with_layout(
                project,
                "feat",
                command_layout,
                :project
              )
            end
          end

          aggregate_failures do
            expect(result).to eq(
              Orn::Tmux::OpenWindowResult.new(
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

    describe "#open_window_non_interactive" do
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
              client.open_window_non_interactive(project, "feat")
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

          result = with_version_check_state(true) do
            with_stdin(StringIO.new("")) do
              client.open_window_non_interactive(project, "feat")
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

    describe "#open_window" do
      it "creates the window in the configured session at the worktree path, seeding with the base window" do
        project = open_project("git:\n  base: main\ntmux:\n  session: proj\n")
        worktree_path = project.worktree_path("feat")

        with_fake_cmd do |fake|
          fake.script(proj_has_session_argv, status: 1)
          fake.script(new_session_argv(worktree_path))
          fake.script(proj_new_window_argv(worktree_path), stdout: "%0\n")
          fake.script(split_argv(worktree_path), stdout: "%1\n")
          fake.script(["tmux", "select-pane", "-t", "%0"])
          fake.script(["tmux", "select-window", "-t", "proj:feat"])

          result = with_version_check_state(true) { client.open_window(project, "feat") }

          aggregate_failures do
            expect(result).to have_attributes(
              branch: "feat",
              session: "proj"
            )
            expect(fake.invocations).to eq(
              [
                proj_has_session_argv,
                proj_has_session_argv,
                new_session_argv(worktree_path),
                proj_new_window_argv(worktree_path),
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

  context "with a real tmux server", :real_cmd, if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    let(:session) { "orn-tmux-spec" }
    # A column of two empty-command panes (a real split, no live-shell wait)
    # and an empty single-pane layout.
    let(:columns_layout) do
      Orn::Config::Layout.of_columns([Orn::Config::Column.new(panes: ["", ""])])
    end
    let(:one_pane_layout) { Orn::Config::Layout.of_columns([]) }

    def create_window_in(path, session, window, layout)
      client.create_window(
        session,
        window,
        path,
        layout,
        default_window_name: window
      )
    end

    def pane_ids(session)
      client.list_panes_metadata(session).map(&:pane_id)
    end

    it "adds a window to an existing session and can remove it" do
      Dir.mktmpdir do |path|
        client.ensure_session(session, path)
        expect(client.window_exists?(session, "feature")).to be(false)

        client.create_window(
          session,
          "feature",
          path,
          columns_layout
        )

        expect(client.list_windows(session)).to include("feature")
        expect(client.window_exists?(session, "feature")).to be(true)

        client.kill_window(session, "feature")
        expect(client.window_exists?(session, "feature")).to be(false)
      end
    end

    it "creates the seed window directly when it is the default window" do
      Dir.mktmpdir do |path|
        client.create_window(
          session,
          "main",
          path,
          columns_layout,
          default_window_name: "main"
        )

        expect(client.list_windows(session)).to eq(["main"])
      end
    end

    it "reports no windows for a session that does not exist" do
      expect(client.list_windows("orn-tmux-absent")).to eq([])
    end

    it "lists live sessions with their activity times" do
      Dir.mktmpdir do |path|
        client.ensure_session(session, path)

        sessions = client.list_sessions

        aggregate_failures do
          expect(sessions.map(&:name)).to include(session)
          expect(sessions.map(&:activity)).to all(be_positive)
        end
      end
    end

    it "reports the canonicalized path a session is rooted at" do
      Dir.mktmpdir do |path|
        client.ensure_session(session, path)

        expect(client.session_path(session)).to eq(File.realpath(path))
      end
    end

    it "lists pane metadata for a session" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          session,
          "feature",
          columns_layout
        )

        feature_panes = client.list_panes_metadata(session)

        aggregate_failures do
          expect(feature_panes.length).to eq(2)
          expect(feature_panes.map(&:window_name)).to all(eq("feature"))
          expect(feature_panes).to all(have_attributes(session_name: nil))
          expect(feature_panes.map(&:pane_pid)).to all(be_positive)
          expect(feature_panes.map(&:pane_id)).to all(start_with("%"))
        end
      end
    end

    it "lists all panes across the server tagged with their session" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          session,
          "feature",
          columns_layout
        )

        panes = client.list_all_panes_metadata

        aggregate_failures do
          expect(panes.length).to eq(2)
          expect(panes.map(&:session_name)).to all(eq(session))
        end
      end
    end

    it "returns nil from the all-panes listing when no server is running" do
      expect(client.list_all_panes_metadata).to be_nil
    end

    it "captures a pane's visible contents as a string" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          session,
          "feature",
          columns_layout
        )
        pane_id = pane_ids(session).first

        expect(client.capture_pane(pane_id)).to be_a(String)
      end
    end

    it "tags a pane, lists it as borrowed, then clears the tags" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          "home-sess",
          "home-win",
          one_pane_layout
        )
        pane = pane_ids("home-sess").first
        client.set_pane_option(
          pane,
          Orn::Tmux::OPT_HOME_SESSION,
          "home-sess"
        )
        client.set_pane_option(
          pane,
          Orn::Tmux::OPT_HOME_WINDOW,
          "home-win"
        )

        expect(client.list_borrowed_panes).to contain_exactly(
          Orn::Tmux::BorrowedPane.new(
            pane_id: pane,
            home_session: "home-sess",
            home_window: "home-win"
          )
        )

        client.unset_pane_option(pane, Orn::Tmux::OPT_HOME_SESSION)
        client.unset_pane_option(pane, Orn::Tmux::OPT_HOME_WINDOW)
        expect(client.list_borrowed_panes).to be_empty
      end
    end

    it "reports the session and window containing a pane" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          "sess-a",
          "win-a",
          one_pane_layout
        )
        pane = pane_ids("sess-a").first

        expect(client.current_session_window(pane)).to eq(%w[sess-a win-a])
      end
    end

    it "returns the active pane of a window" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          "sess-b",
          "win-b",
          columns_layout
        )
        panes = pane_ids("sess-b")
        client.select_pane(panes.last)

        expect(client.active_pane("sess-b", "win-b")).to eq(panes.last)
      end
    end

    it "borrows a pane into another window and breaks it back out" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          "src",
          "work",
          columns_layout
        )
        borrowed = pane_ids("src").last
        create_window_in(
          path,
          "hub",
          "orn",
          one_pane_layout
        )

        client.join_pane(
          borrowed,
          "hub:orn",
          33,
          false
        )
        expect(pane_ids("hub")).to include(borrowed)

        client.break_pane(
          borrowed,
          "src",
          "returned"
        )
        expect(client.list_windows("src")).to include("returned")
      end
    end

    it "recreates a session around a surviving pane" do
      Dir.mktmpdir do |path|
        create_window_in(
          path,
          "orig",
          "w",
          columns_layout
        )
        pane = pane_ids("orig").last

        client.recreate_session_with_pane(
          pane,
          "revived",
          "back"
        )

        expect(client.list_windows("revived")).to eq(["back"])
      end
    end

    it "installs a guarded root key binding and removes it" do
      Dir.mktmpdir do |path|
        client.ensure_session("kb", path)
        condition = Orn::Tmux.window_guard_condition("kb", "orn")
        client.bind_key_guarded(
          "M-o",
          condition,
          "display-message borrowed"
        )

        expect(root_key_bindings).to include("M-o")

        client.unbind_key("M-o")
        expect(root_key_bindings).not_to include("M-o")
      end
    end

    def root_key_bindings
      Orn::Cmd.new(output_mode: output_mode).output("tmux", "list-keys", "-T", "root").stdout
    end
  end
end
