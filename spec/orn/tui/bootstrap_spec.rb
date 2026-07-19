# frozen_string_literal: true

require "json"
require "tmpdir"

module Orn
  module TUI
    RSpec.describe Bootstrap do
      def project_app
        App.new(
          output_mode: Orn::OutputMode.quiet,
          root: "/tmp/nonexistent",
          session: "test",
          base_branch: "main"
        )
      end

      def global_app
        GlobalApp.new(
          output_mode: Orn::OutputMode.quiet,
          config: Orn::Config::GlobalTuiConfig.new(
            session: "orn",
            scan_roots: [],
            scan_depth: 3
          )
        )
      end

      def char(character)
        KeyEvent.char(character)
      end

      def output_mode
        Orn::OutputMode.quiet
      end

      def list_windows_argv(session)
        ["tmux", "list-windows", "-t", "#{session}:", "-F", "\#{window_name}"]
      end

      def tui_pane_command_argv(session)
        ["tmux", "list-panes", "-t", "#{session}:orn", "-F", "\#{pane_current_command}"]
      end

      def select_tui_window_argv(session)
        ["tmux", "select-window", "-t", "#{session}:orn"]
      end

      def kill_tui_window_argv(session)
        ["tmux", "kill-window", "-t", "#{session}:orn"]
      end

      # The tmux answers for a session whose `orn` window is open and still
      # running the TUI, so reuse selects it instead of launching a new one.
      def script_live_tui_window(fake, session)
        fake.script(list_windows_argv(session), stdout: "orn\n")
        fake.script(tui_pane_command_argv(session), stdout: "orn\n")
        fake.script(select_tui_window_argv(session))
      end

      # An in-memory terminal backend that also accepts the start/stop
      # lifecycle calls with_terminal makes on the real backend.
      def scripted_terminal_backend(*key_events)
        backend = TestBackend.new(40, 8)
        backend.feed(*key_events)
        def backend.start; end
        def backend.stop; end
        backend
      end

      # with_terminal traps INT and TERM; snapshot and restore the handlers so
      # an example does not replace RSpec's interrupt handling for the rest of
      # the run.
      def preserving_signal_traps
        previous_int = Signal.trap("INT", "DEFAULT")
        Signal.trap("INT", previous_int)
        previous_term = Signal.trap("TERM", "DEFAULT")
        Signal.trap("TERM", previous_term)
        yield
      ensure
        Signal.trap("INT", previous_int)
        Signal.trap("TERM", previous_term)
      end

      describe ".run" do
        def stub_entry_points
          allow(described_class).to receive(:run_direct)
          allow(described_class).to receive(:run_global_direct)
          allow(described_class).to receive(:bootstrap)
          allow(described_class).to receive(:bootstrap_global)
        end

        def run_from(directory, orn_tui:, global:)
          stub_entry_points
          if orn_tui
            ENV["ORN_TUI"] = "1"
          else
            ENV.delete("ORN_TUI")
          end
          Dir.chdir(directory) { described_class.run(global: global) }
        end

        routing_cases = [
          {
            expected: :run_global_direct,
            orn_tui: true,
            global: true,
            in_project: true,
            description: "runs the global loop directly when re-execed with a global request"
          },
          {
            expected: :run_global_direct,
            orn_tui: true,
            global: false,
            in_project: false,
            description: "runs the global loop directly when re-execed outside any project"
          },
          {
            expected: :run_direct,
            orn_tui: true,
            global: false,
            in_project: true,
            description: "runs the project loop directly when re-execed inside a project"
          },
          {
            expected: :bootstrap_global,
            orn_tui: false,
            global: true,
            in_project: true,
            description: "bootstraps the global TUI window when the global TUI is requested"
          },
          {
            expected: :bootstrap_global,
            orn_tui: false,
            global: false,
            in_project: false,
            description: "bootstraps the global TUI window when no project is found"
          },
          {
            expected: :bootstrap,
            orn_tui: false,
            global: false,
            in_project: true,
            description: "bootstraps the project TUI window from inside a project"
          }
        ]

        routing_cases.each do |routing_case|
          it routing_case[:description] do
            isolate_global_config
            directory = routing_case[:in_project] ? make_bare_project : register_temp_dir(Dir.mktmpdir("orn-plain"))

            run_from(
              directory,
              orn_tui: routing_case[:orn_tui],
              global: routing_case[:global]
            )

            expect(described_class).to have_received(routing_case[:expected])
          end
        end

        it "hands the discovered project to the project loop" do
          isolate_global_config
          root = make_bare_project

          run_from(
            root,
            orn_tui: true,
            global: false
          )

          expect(described_class).to have_received(:run_direct) do |project|
            expect(project.root).to eq(File.realpath(root))
          end
        end
      end

      describe ".discover_project" do
        it "returns the project discovered from the current directory" do
          isolate_global_config
          root = make_bare_project

          project = Dir.chdir(root) { described_class.discover_project }

          expect(project.root).to eq(File.realpath(root))
        end

        it "returns nil when the current directory is not an orn project" do
          plain_dir = register_temp_dir(Dir.mktmpdir("orn-plain"))

          project = Dir.chdir(plain_dir) { described_class.discover_project }

          expect(project).to be_nil
        end
      end

      describe ".run_direct" do
        it "records the project in the MRU state before running the loop" do
          state_home = register_temp_dir(Dir.mktmpdir("orn-state"))
          ENV["XDG_STATE_HOME"] = state_home
          project = make_project(make_bare_project)
          app = project_app
          allow(App).to receive(:for_project).and_return(app)
          allow(TermBackend).to receive(:new).and_return(scripted_terminal_backend(char("q")))

          preserving_signal_traps { described_class.run_direct(project) }

          state_path = File.join(
            state_home,
            "orn",
            "tui.json"
          )
          state_json = JSON.parse(File.read(state_path))
          aggregate_failures do
            expect(state_json["mru"].keys).to eq([project.root])
            expect(App).to have_received(:for_project).with(
              an_instance_of(Orn::OutputMode),
              project
            )
          end
        end
      end

      describe ".with_terminal" do
        # The trap handler calls exit; RSpec stubs synchronize on a mutex,
        # which Ruby forbids in trap context, so exit is intercepted with a
        # plain singleton method and the backend records stops into an array.
        def install_interceptors
          stops = []
          exit_codes = []
          backend = scripted_terminal_backend
          backend.define_singleton_method(:stop) { stops << :stop }
          allow(TermBackend).to receive(:new).and_return(backend)
          described_class.define_singleton_method(:exit) { |code| exit_codes << code }
          [stops, exit_codes]
        end

        after do
          described_class.singleton_class.remove_method(:exit)
        rescue NameError
          nil
        end

        it "restores the terminal and exits when the process is interrupted" do
          stops, exit_codes = install_interceptors
          stops_when_handler_ran = nil
          preserving_signal_traps do
            described_class.with_terminal do |_terminal|
              Process.kill("INT", Process.pid)
              sleep(0.01) while exit_codes.empty?
              stops_when_handler_ran = stops.length
            end
          end

          aggregate_failures do
            expect(exit_codes).to eq([1])
            expect(stops_when_handler_ran).to eq(1)
            expect(stops.length).to eq(2)
          end
        end
      end

      describe ".run_global_direct" do
        def borrowed_list_argv
          ["tmux", "list-panes", "-a", "-F", "\#{pane_id}\t\#{@orn_home_session}\t\#{@orn_home_window}"]
        end

        def unbind_argvs
          %w[M-o M-i M-n M-p].map { |key| ["tmux", "unbind-key", "-n", key] }
        end

        def script_hub_cleanup(fake)
          fake.script(borrowed_list_argv)
          unbind_argvs.each { |argv| fake.script(argv) }
        end

        # The app the stubbed GlobalApp.build returns, with close_all_tabs
        # spied so the examples can assert the ensure block ran.
        def global_app_with_close_spy
          app = global_app
          allow(app).to receive(:close_all_tabs)
          app
        end

        def install_terminal_backend(*key_events)
          allow(TermBackend).to receive(:new).and_return(scripted_terminal_backend(*key_events))
        end

        # Stubs GlobalApp.build to return `app`, recording which tmux commands
        # had already run by the time the build happened.
        def stub_global_app_build(fake, app)
          invocations_at_build = []
          allow(GlobalApp).to receive(:build) do
            invocations_at_build.concat(fake.invocations)
            app
          end
          invocations_at_build
        end

        it "returns stranded panes and clears stale bindings before building the app" do
          isolate_global_config
          app = global_app_with_close_spy
          install_terminal_backend(char("q"))
          with_fake_cmd do |fake|
            script_hub_cleanup(fake)
            invocations_at_build = stub_global_app_build(fake, app)

            preserving_signal_traps { described_class.run_global_direct }

            aggregate_failures do
              expect(invocations_at_build).to eq([borrowed_list_argv, *unbind_argvs])
              expect(app).to have_received(:close_all_tabs)
            end
          end
        end

        it "closes all tabs even when the loop fails" do
          isolate_global_config
          app = global_app_with_close_spy
          allow(app).to receive(:poll_focus).and_raise(RuntimeError, "loop crashed")
          install_terminal_backend
          with_fake_cmd do |fake|
            script_hub_cleanup(fake)
            allow(GlobalApp).to receive(:build).and_return(app)

            expect do
              preserving_signal_traps { described_class.run_global_direct }
            end.to raise_error(RuntimeError, "loop crashed")
            expect(app).to have_received(:close_all_tabs)
          end
        end
      end

      describe ".bootstrap" do
        it "selects the live TUI window, pinning the base branch second" do
          project = make_project(make_bare_project)
          session = File.basename(project.root)
          swap_argv = ["tmux", "swap-window", "-d", "-s", "#{session}:main", "-t", "#{session}:orn"]
          with_fake_cmd do |fake|
            fake.script(list_windows_argv(session), stdout: "main\norn\n")
            fake.script(tui_pane_command_argv(session), stdout: "orn\n")
            fake.script(swap_argv)
            fake.script(select_tui_window_argv(session))

            described_class.bootstrap(project)

            expect(fake.invocations).to eq(
              [
                list_windows_argv(session),
                tui_pane_command_argv(session),
                list_windows_argv(session),
                swap_argv,
                select_tui_window_argv(session)
              ]
            )
          end
        end
      end

      describe ".bootstrap_global" do
        it "selects the live global TUI window in the configured session" do
          isolate_global_config
          with_fake_cmd do |fake|
            script_live_tui_window(fake, "orn")

            described_class.bootstrap_global

            expect(fake.invocations).to eq(
              [
                list_windows_argv("orn"),
                tui_pane_command_argv("orn"),
                list_windows_argv("orn"),
                select_tui_window_argv("orn")
              ]
            )
          end
        end
      end

      describe ".bootstrap_tui" do
        def bootstrap_repo_tui
          described_class.bootstrap_tui(
            output_mode,
            "repo",
            "/tmp/wt",
            default_window_name: "main",
            reorder_base: "main",
            relaunch_suffix: ""
          )
        end

        it "launches nothing when a live TUI window is reused" do
          ENV["TMUX"] = "/tmp/tmux-1000/default,1234,0"
          with_fake_cmd do |fake|
            script_live_tui_window(fake, "repo")

            bootstrap_repo_tui

            expect(fake.invocations).to eq(
              [
                list_windows_argv("repo"),
                tui_pane_command_argv("repo"),
                list_windows_argv("repo"),
                select_tui_window_argv("repo")
              ]
            )
          end
        end

        it "adds the TUI window to the ensured session when already inside tmux" do
          ENV["TMUX"] = "/tmp/tmux-1000/default,1234,0"
          new_window_argv = [
            "tmux",
            "new-window",
            "-a",
            "-t",
            "repo:",
            "-n",
            "orn",
            "-c",
            "/tmp/wt",
            Orn::TUI.relaunch_command("")
          ]
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "main\n")
            fake.script(["tmux", "has-session", "-t", "repo"])
            fake.script(new_window_argv)
            fake.script(select_tui_window_argv("repo"))

            bootstrap_repo_tui

            expect(fake.invocations).to eq(
              [
                list_windows_argv("repo"),
                ["tmux", "has-session", "-t", "repo"],
                new_window_argv,
                list_windows_argv("repo"),
                select_tui_window_argv("repo")
              ]
            )
          end
        end

        it "creates and attaches a new session when outside tmux" do
          ENV.delete("TMUX")
          allow(described_class).to receive(:system).and_return(true)
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "main\n")

            bootstrap_repo_tui

            expect(described_class).to have_received(:system).with(
              "tmux",
              "new-session",
              "-s",
              "repo",
              "-n",
              "orn",
              "-c",
              "/tmp/wt",
              Orn::TUI.relaunch_command("")
            )
          end
        end
      end

      describe ".reuse_existing_window" do
        it "reports false when no TUI window exists" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "main\n")

            reused = described_class.reuse_existing_window(output_mode, "repo", "main")

            expect(reused).to be(false)
          end
        end

        it "selects a window whose pane still runs orn and reports true" do
          with_fake_cmd do |fake|
            script_live_tui_window(fake, "repo")

            reused = described_class.reuse_existing_window(output_mode, "repo", "main")

            aggregate_failures do
              expect(reused).to be(true)
              expect(fake.invocations).to include(select_tui_window_argv("repo"))
            end
          end
        end

        it "kills a stale window whose pane no longer runs orn and reports false" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "orn\n")
            fake.script(tui_pane_command_argv("repo"), stdout: "zsh\n")
            fake.script(kill_tui_window_argv("repo"))

            reused = described_class.reuse_existing_window(output_mode, "repo", "main")

            aggregate_failures do
              expect(reused).to be(false)
              expect(fake.invocations).to include(kill_tui_window_argv("repo"))
            end
          end
        end

        it "reports false even when killing the stale window fails" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "orn\n")
            fake.script(tui_pane_command_argv("repo"), stdout: "zsh\n")
            fake.script(
              kill_tui_window_argv("repo"),
              stderr: "no such window",
              status: 1
            )

            reused = described_class.reuse_existing_window(output_mode, "repo", "main")

            expect(reused).to be(false)
          end
        end
      end

      describe ".launch_session" do
        it "raises when the tmux session exits with an error" do
          allow(described_class).to receive(:system).and_return(false)

          expect do
            described_class.launch_session(
              "repo",
              "/tmp/wt",
              "ORN_TUI=1 exec orn"
            )
          end.to raise_error(Orn::Error, "tmux session exited with an error")
        end
      end

      describe ".dispatch_project" do
        it "signals quit on q in normal mode" do
          expect(described_class.dispatch_project(project_app, char("q"))).to eq(:quit)
        end

        it "enters new-branch mode on n" do
          app = project_app
          described_class.dispatch_project(app, char("n"))

          expect(app.mode).to eq(Mode.new_branch(""))
        end

        it "accumulates typed characters while in new-branch mode" do
          app = project_app
          app.start_new_branch
          described_class.dispatch_project(app, char("x"))

          expect(app.mode).to eq(Mode.new_branch("x"))
        end

        it "submits the new-branch input on enter, leaving new-branch mode" do
          app = project_app
          app.start_new_branch
          described_class.dispatch_project(app, KeyEvent.key(:enter))

          expect(app.mode).to eq(Mode.normal)
        end

        it "removes the last typed character on backspace" do
          app = project_app
          app.start_new_branch
          described_class.dispatch_project(app, char("x"))
          described_class.dispatch_project(app, KeyEvent.key(:backspace))

          expect(app.mode).to eq(Mode.new_branch(""))
        end

        it "cancels new-branch mode on escape" do
          app = project_app
          app.start_new_branch
          described_class.dispatch_project(app, KeyEvent.key(:esc))

          expect(app.mode).to eq(Mode.normal)
        end

        it "cancels a remove confirmation on any key but y" do
          app = project_app
          app.instance_variable_set(:@mode, Mode.confirm_remove("feat"))
          described_class.dispatch_project(app, char("n"))

          expect(app.mode).to eq(Mode.normal)
        end

        it "clears a pending error on any key press" do
          app = project_app
          app.error = "boom"
          described_class.dispatch_project(app, char("k"))

          expect(app.error).to be_nil
        end
      end

      describe ".dispatch_global" do
        it "signals quit on q" do
          expect(described_class.dispatch_global(global_app, char("q"))).to eq(:quit)
        end

        it "toggles expansion on space" do
          app = global_app
          app.entries = [
            RepoEntry.new(
              display_name: "a",
              root: "/tmp/x",
              healthy: true,
              session_name: "a",
              base_branch: "main",
              worktrees: []
            )
          ]
          app.sync_list_state
          described_class.dispatch_global(app, char(" "))

          expect(app.entries[0].expanded).to be(true)
        end

        it "cycles the visible tab forward on n" do
          app = global_app
          allow(app).to receive(:cycle_tab)
          described_class.dispatch_global(app, char("n"))

          expect(app).to have_received(:cycle_tab).with(true)
        end

        it "cycles the visible tab backward on p" do
          app = global_app
          allow(app).to receive(:cycle_tab)
          described_class.dispatch_global(app, char("p"))

          expect(app).to have_received(:cycle_tab).with(false)
        end

        it "does not quit on other keys", :real_cmd do
          expect(described_class.dispatch_global(global_app, char("r"))).to be_nil
        end
      end

      describe ".run_loop" do
        it "draws and returns when quit is pressed" do
          backend = TestBackend.new(40, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)

          described_class.run_loop(terminal, project_app)

          expect(backend.buffer.to_s).to include("orn")
        end

        it "does not clear the screen without a resize" do
          backend = TestBackend.new(40, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)

          described_class.run_loop(terminal, project_app)

          expect(backend.clears).to eq(0)
        end

        it "clears and redraws at the new size when the terminal resizes" do
          backend = TestBackend.new(40, 8)
          backend.feed_resize(20, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)

          described_class.run_loop(terminal, project_app)

          expect(backend.clears).to eq(1)
          expect(backend.buffer.area.width).to eq(20)
        end
      end

      describe ".run_global_loop" do
        it "draws and returns when quit is pressed" do
          backend = TestBackend.new(40, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)

          described_class.run_global_loop(terminal, global_app)

          expect(backend.buffer.to_s).to include("No orn repos found")
        end

        it "re-applies the layout and clears when the terminal resizes" do
          backend = TestBackend.new(40, 8)
          backend.feed_resize(20, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)
          app = global_app
          allow(app).to receive(:enforce_layout)

          described_class.run_global_loop(terminal, app)

          expect(app).to have_received(:enforce_layout)
          expect(backend.clears).to eq(1)
        end

        it "does not re-apply the layout without a resize" do
          backend = TestBackend.new(40, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)
          app = global_app
          allow(app).to receive(:enforce_layout)

          described_class.run_global_loop(terminal, app)

          expect(app).not_to have_received(:enforce_layout)
        end
      end
    end
  end
end
