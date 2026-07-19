# frozen_string_literal: true

require "tmpdir"

module Orn
  module TUI
    RSpec.describe App do
      def build_app(branches, root: "/tmp/nonexistent", symlinks: nil)
        app = described_class.new(
          output_mode: Orn::OutputMode.quiet,
          root: root,
          session: "test",
          base_branch: "main",
          symlinks: symlinks
        )
        app.entries = branches.map { |name| status(name) }
        app
      end

      def status(branch, has_window: false)
        WorktreeStatus.new(
          branch: branch,
          dirty: false,
          has_window: has_window,
          ahead: 0,
          behind: 0
        )
      end

      def working_state
        Orn::Detect::PaneAgentState.new(
          agent: :claude,
          state: :working
        )
      end

      # A root for scripted examples: every command against it goes through the
      # fake backend, so the path never has to exist.
      def scripted_root
        "/tmp/orn-approot"
      end

      def git_argv(root, *args)
        ["git", "-C", root, *args]
      end

      def worktree_list_argv(root)
        git_argv(
          root,
          "worktree",
          "list",
          "--porcelain"
        )
      end

      def list_windows_argv(session = "test")
        ["tmux", "list-windows", "-t", "#{session}:", "-F", "\#{window_name}"]
      end

      def borrowed_panes_argv
        ["tmux", "list-panes", "-a", "-F", "\#{pane_id}\t\#{@orn_home_session}\t\#{@orn_home_window}"]
      end

      def session_panes_argv(session = "test")
        pane_format = "\#{window_name}\t\#{pane_pid}\t\#{pane_current_command}\t\#{pane_id}\t\#{pane_title}"
        ["tmux", "list-panes", "-s", "-t", "#{session}:", "-F", pane_format]
      end

      def new_window_argv(root, branch)
        [
          "tmux",
          "new-window",
          "-a",
          "-P",
          "-F",
          "\#{pane_id}",
          "-t",
          "test:",
          "-n",
          branch,
          "-c",
          File.join(root, branch)
        ]
      end

      def kill_window_argv(branch)
        ["tmux", "kill-window", "-t", "test:#{branch}"]
      end

      def select_window_argv(branch)
        ["tmux", "select-window", "-t", "test:#{branch}"]
      end

      # The tmux calls a bare (no layout) window creation issues against an
      # existing session. `tmux -V` runs at most once per process, so it is
      # scripted but never asserted on.
      def script_bare_window(fake, root, branch)
        fake.script(["tmux", "-V"], stdout: "tmux 3.4\n")
        fake.script(["tmux", "has-session", "-t", "test"])
        fake.script(new_window_argv(root, branch), stdout: "%9\n")
        fake.script(select_window_argv(branch))
      end

      def script_refresh(fake, root, windows: "")
        fake.script(list_windows_argv, stdout: windows)
        fake.script(worktree_list_argv(root))
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      describe "selection movement" do
        it "moves down, wrapping past the end" do
          app = build_app(%w[a b c])

          aggregate_failures do
            app.move_down
            expect(app.selected).to eq(1)
            app.move_down
            app.move_down
            expect(app.selected).to eq(0)
          end
        end

        it "moves up, wrapping past the start" do
          app = build_app(%w[a b c])

          aggregate_failures do
            app.move_up
            expect(app.selected).to eq(2)
            app.move_up
            expect(app.selected).to eq(1)
          end
        end

        it "does nothing on an empty list" do
          app = build_app([])

          aggregate_failures do
            app.move_down
            app.move_up
            expect(app.selected).to eq(0)
          end
        end

        it "stays put with a single item" do
          app = build_app(%w[only])

          app.move_down
          app.move_up
          expect(app.selected).to eq(0)
        end
      end

      describe "input modes" do
        it "enters new-branch mode with an empty input" do
          app = build_app([])
          app.start_new_branch

          expect(app.mode).to eq(Mode.new_branch(""))
        end

        it "accumulates and backspaces typed characters" do
          app = build_app([])
          app.start_new_branch
          app.new_branch_push_char("a")
          app.new_branch_push_char("b")
          app.new_branch_pop_char

          expect(app.mode).to eq(Mode.new_branch("a"))
        end

        it "enters confirm-remove mode for the selected branch" do
          app = build_app(%w[feature/x])
          app.start_remove

          expect(app.mode).to eq(Mode.confirm_remove("feature/x"))
        end

        it "does not enter confirm-remove on an empty list" do
          app = build_app([])
          app.start_remove

          expect(app.mode).to eq(Mode.normal)
        end

        it "returns to normal mode on cancel" do
          app = build_app([])
          app.start_new_branch
          app.cancel_mode

          expect(app.mode).to eq(Mode.normal)
        end

        it "returns to normal mode when confirming an empty branch name" do
          app = build_app([])
          app.start_new_branch
          app.confirm_new_branch

          expect(app.mode).to eq(Mode.normal)
        end

        it "ignores typed characters outside new-branch mode" do
          app = build_app([])
          app.new_branch_push_char("a")
          app.new_branch_pop_char

          expect(app.mode).to eq(Mode.normal)
        end

        it "does nothing when confirming outside new-branch mode" do
          app = build_app(%w[feat])
          with_fake_cmd do |fake|
            app.confirm_new_branch

            expect(fake.invocations).to be_empty
          end
        end
      end

      describe "agent state" do
        it "starts with no agent states" do
          expect(build_app(%w[main]).agent_states).to be_empty
        end

        it "reports an agent working" do
          app = build_app(%w[main])
          app.agent_states["main"] = working_state

          expect(app.any_agent_working?).to be(true)
        end

        it "does not report idle or blocked agents as working" do
          app = build_app(%w[main])
          app.agent_states["main"] = Orn::Detect::PaneAgentState.new(
            agent: :claude,
            state: :idle
          )

          expect(app.any_agent_working?).to be(false)
        end

        it "polls fast while an agent works and normally otherwise" do
          app = build_app(%w[main])

          aggregate_failures do
            expect(app.poll_timeout).to eq(POLL_TIMEOUT)
            app.agent_states["main"] = working_state
            expect(app.poll_timeout).to eq(FAST_POLL_TIMEOUT)
          end
        end
      end

      describe "errors" do
        it "clears an error" do
          app = build_app([])
          app.error = "oops"
          app.clear_error

          expect(app.error).to be_nil
        end
      end

      describe ".for_project" do
        def project_with_sbx_agent
          root = register_temp_dir(Dir.mktmpdir("orn-approot"))
          make_project(root, <<~YAML)
            git:
              base: main
            tmux:
              session: appsess
            sbx:
              agent_type: claude
          YAML
        end

        it "reads the session, base, and repo name from the project and refreshes" do
          project = project_with_sbx_agent
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("appsess"), status: 1)
            fake.script(worktree_list_argv(project.root))

            app = described_class.for_project(
              Orn::OutputMode.quiet,
              project
            )

            aggregate_failures do
              expect(app.session).to eq("appsess")
              expect(app.base_branch).to eq("main")
              expect(app.repo_name).to eq(File.basename(project.root))
              expect(fake.invocations).to include(worktree_list_argv(project.root))
            end
          end
        end

        it "builds without an sbx agent when the config has none" do
          root = register_temp_dir(Dir.mktmpdir("orn-approot"))
          project = make_project(root, "git:\n  base: main\n")
          session = File.basename(root)
          with_fake_cmd do |fake|
            fake.script(list_windows_argv(session), status: 1)
            fake.script(worktree_list_argv(root))

            app = described_class.for_project(
              Orn::OutputMode.quiet,
              project
            )

            expect(app.session).to eq(session)
          end
        end

        it "attributes container panes to the configured sbx agent" do
          isolate_global_config
          project = project_with_sbx_agent
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("appsess"), status: 1)
            fake.script(worktree_list_argv(project.root))
            # A pane whose command is a container runtime and whose pid cannot
            # exist, so detection falls through to the sbx agent type.
            fake.script(
              session_panes_argv("appsess"),
              stdout: "feat\t4999999999\tdocker\t%1\tt\n"
            )
            fake.script(["tmux", "capture-pane", "-p", "-t", "%1"])

            app = described_class.for_project(
              Orn::OutputMode.quiet,
              project
            )
            app.refresh_agents

            expect(app.agent_states["feat"].agent).to eq(:claude)
          end
        end
      end

      describe "#refresh" do
        it "rebuilds the rows from git and clamps the selection to the new length" do
          app = build_app(
            %w[a b c],
            root: scripted_root
          )
          app.selected = 2
          wt_path = File.join(scripted_root, "feat")
          with_fake_cmd do |fake|
            fake.script(list_windows_argv, stdout: "feat\n")
            fake.script(
              worktree_list_argv(scripted_root),
              stdout: "worktree #{wt_path}\nbranch refs/heads/feat\n"
            )
            fake.script(
              git_argv(
                wt_path,
                "rev-list",
                "--left-right",
                "--count",
                "feat...main"
              ),
              stdout: "1\t2\n"
            )
            fake.script(git_argv(wt_path, "status", "--porcelain"), stdout: " M f.txt\n")

            app.refresh

            aggregate_failures do
              expect(app.selected).to eq(0)
              expect(app.entries).to eq(
                [
                  WorktreeStatus.new(
                    branch: "feat",
                    dirty: true,
                    has_window: true,
                    ahead: 1,
                    behind: 2
                  )
                ]
              )
            end
          end
        end
      end

      describe "#refresh_agents" do
        it "records a state per window from the session's panes" do
          app = build_app([], root: scripted_root)
          with_fake_cmd do |fake|
            fake.script(
              session_panes_argv,
              stdout: "feat\t4999999999\tzsh\t%1\tt\n"
            )

            app.refresh_agents

            expect(app.agent_states).to eq(
              "feat" => Orn::Detect::PaneAgentState.new(
                agent: nil,
                state: :unknown
              )
            )
          end
        end

        it "clears the states when the pane listing fails" do
          app = build_app([], root: scripted_root)
          app.agent_states["feat"] = working_state
          with_fake_cmd do |fake|
            fake.script(session_panes_argv, status: 1)

            app.refresh_agents

            expect(app.agent_states).to be_empty
          end
        end
      end

      describe "#maybe_refresh" do
        # The refresh cadence is tracked against a monotonic clock with no
        # injection seam, so the recorded times are rewound to make both
        # refreshes due.
        it "runs both refreshes once their intervals have elapsed" do
          app = build_app([], root: scripted_root)
          app.instance_variable_set(:@last_refresh, monotonic_now - 60)
          app.instance_variable_set(:@last_agent_refresh, monotonic_now - 60)
          with_fake_cmd do |fake|
            fake.script(session_panes_argv, status: 1)
            script_refresh(fake, scripted_root)

            app.maybe_refresh

            expect(fake.invocations).to include(
              session_panes_argv,
              list_windows_argv
            )
          end
        end

        it "skips both refreshes inside their intervals" do
          app = build_app([], root: scripted_root)
          with_fake_cmd do |fake|
            app.maybe_refresh

            expect(fake.invocations).to be_empty
          end
        end
      end

      describe ".dirty?" do
        def status_argv
          git_argv(
            "/repo/feat",
            "status",
            "--porcelain"
          )
        end

        def query_dirty
          described_class.dirty?(
            Orn::OutputMode.quiet,
            "/repo/feat"
          )
        end

        it "is true when git reports changes" do
          with_fake_cmd do |fake|
            fake.script(status_argv, stdout: " M f.txt\n")

            expect(query_dirty).to be(true)
          end
        end

        it "is false when the tree is clean" do
          with_fake_cmd do |fake|
            fake.script(status_argv, stdout: "\n")

            expect(query_dirty).to be(false)
          end
        end

        it "is false when git exits nonzero" do
          with_fake_cmd do |fake|
            fake.script(status_argv, status: 128)

            expect(query_dirty).to be(false)
          end
        end

        it "is false when git is missing" do
          with_fake_cmd do |fake|
            fake.script_missing(status_argv)

            expect(query_dirty).to be(false)
          end
        end
      end

      describe ".ahead_behind" do
        def rev_list_argv
          git_argv(
            "/repo/feat",
            "rev-list",
            "--left-right",
            "--count",
            "feat...main"
          )
        end

        def query_counts
          described_class.ahead_behind(
            Orn::OutputMode.quiet,
            "/repo/feat",
            "feat",
            "main"
          )
        end

        it "parses the left-right counts" do
          with_fake_cmd do |fake|
            fake.script(rev_list_argv, stdout: "2\t1\n")

            expect(query_counts).to eq([2, 1])
          end
        end

        it "returns zeros for malformed output" do
          with_fake_cmd do |fake|
            fake.script(rev_list_argv, stdout: "garbage\n")

            expect(query_counts).to eq([0, 0])
          end
        end

        it "returns zeros when git exits nonzero" do
          with_fake_cmd do |fake|
            fake.script(rev_list_argv, status: 128)

            expect(query_counts).to eq([0, 0])
          end
        end

        it "returns zeros when git is missing" do
          with_fake_cmd do |fake|
            fake.script_missing(rev_list_argv)

            expect(query_counts).to eq([0, 0])
          end
        end

        it "returns zeros for an invalid path" do
          counts = described_class.ahead_behind(
            Orn::OutputMode.quiet,
            "/tmp/nonexistent",
            "feature",
            "main"
          )

          expect(counts).to eq([0, 0])
        end
      end

      describe "#confirm_new_branch", if: TmuxSpecSupport::AVAILABLE do
        include_context "with an isolated tmux server"

        def remote_backed_project(branch)
          remote = make_remote_with_branch(branch)
          root = make_bare_project
          add_origin(root, remote)
          File.write(
            File.join(
              root,
              ".orn",
              "config.yaml"
            ),
            "git:\n  base: main\n"
          )
          worktree = Orn::Git::Worktree.new(
            root: root,
            output_mode: Orn::OutputMode.quiet
          )
          worktree.fetch("origin", "main")
          worktree.add(
            File.join(root, "main"),
            "main",
            "origin/main"
          )
          root
        end

        def app_for(root)
          described_class.new(
            output_mode: Orn::OutputMode.quiet,
            root: root,
            session: "orn-app-spec",
            base_branch: "main"
          )
        end

        it "creates a worktree tracking the remote branch when it exists" do
          root = remote_backed_project("feature/remote-only")
          app = app_for(root)
          app.mode = Mode.new_branch("feature/remote-only")

          app.confirm_new_branch

          expect(File).to exist(
            File.join(
              root,
              "feature/remote-only",
              "g.txt"
            )
          )
        end

        it "creates a worktree off base when the branch is not on the remote" do
          root = remote_backed_project("feature/other")
          app = app_for(root)
          app.mode = Mode.new_branch("feature/brand-new")

          app.confirm_new_branch

          aggregate_failures do
            expect(File).to be_directory(File.join(root, "feature/brand-new"))
            expect(File).not_to exist(
              File.join(
                root,
                "feature/brand-new",
                "g.txt"
              )
            )
          end
        end
      end

      describe "#confirm_new_branch with scripted commands" do
        def ls_remote_argv(root, branch)
          git_argv(
            root,
            "ls-remote",
            "--heads",
            "origin",
            branch
          )
        end

        def add_argv(root, branch, start_point)
          git_argv(
            root,
            "worktree",
            "add",
            "-b",
            branch,
            File.join(root, branch),
            start_point
          )
        end

        it "records the error and stops when the remote fetch fails" do
          app = build_app([], root: scripted_root)
          app.mode = Mode.new_branch("feat")
          with_fake_cmd do |fake|
            fake.script(ls_remote_argv(scripted_root, "feat"), stdout: "abc\trefs/heads/feat\n")
            fake.script(
              git_argv(
                scripted_root,
                "fetch",
                "origin",
                "feat"
              ),
              stderr: "network down",
              status: 1
            )

            app.confirm_new_branch

            aggregate_failures do
              expect(app.error).to eq("git failed: network down")
              expect(fake.invocations).not_to include(add_argv(scripted_root, "feat", "origin/feat"))
            end
          end
        end

        it "starts from origin/ for a remote branch and surfaces a creation failure" do
          app = build_app([], root: scripted_root)
          app.mode = Mode.new_branch("feat")
          with_fake_cmd do |fake|
            fake.script(ls_remote_argv(scripted_root, "feat"), stdout: "abc\trefs/heads/feat\n")
            fake.script(
              git_argv(
                scripted_root,
                "fetch",
                "origin",
                "feat"
              )
            )
            fake.script(
              add_argv(scripted_root, "feat", "origin/feat"),
              stderr: "bad origin",
              status: 1
            )
            fake.script(
              add_argv(scripted_root, "feat", "feat"),
              stderr: "bad local",
              status: 1
            )
            fake.script(
              git_argv(
                scripted_root,
                "worktree",
                "add",
                File.join(scripted_root, "feat"),
                "feat"
              ),
              stderr: "bad checkout",
              status: 1
            )

            app.confirm_new_branch

            aggregate_failures do
              expect(fake.invocations).to include(add_argv(scripted_root, "feat", "origin/feat"))
              expect(app.error).to include("Failed to create worktree for 'feat'")
            end
          end
        end

        # A project root sharing main/shared.txt into new worktrees. The feat
        # worktree dir is pre-created because the scripted worktree add touches
        # no disk, and Symlink writes into it.
        def root_with_shared_file
          root = register_temp_dir(Dir.mktmpdir("orn-approot"))
          FileUtils.mkdir_p(File.join(root, "main"))
          File.write(File.join(root, "main", "shared.txt"), "x")
          FileUtils.mkdir_p(File.join(root, "feat"))
          root
        end

        def app_sharing_file(root)
          build_app(
            [],
            root: root,
            symlinks: Orn::Config::SymlinksConfig.new(
              base: ["shared.txt"],
              root: []
            )
          )
        end

        def script_branch_creation_off_base(fake, root, wt_path)
          fake.script(ls_remote_argv(root, "feat"))
          fake.script(add_argv(root, "feat", "main"))
          fake.script(
            git_argv(
              wt_path,
              "check-ignore",
              "-q",
              "shared.txt"
            ),
            status: 1
          )
          fake.script(git_argv(wt_path, "add", ".gitignore"))
          script_bare_window(fake, root, "feat")
          script_refresh(fake, root)
        end

        it "creates the worktree, symlinks, and window off base for a new branch" do
          root = root_with_shared_file
          wt_path = File.join(root, "feat")
          app = app_sharing_file(root)
          app.mode = Mode.new_branch("feat")
          with_fake_cmd do |fake|
            script_branch_creation_off_base(
              fake,
              root,
              wt_path
            )

            app.confirm_new_branch

            aggregate_failures do
              expect(app.error).to be_nil
              expect(File.read(File.join(wt_path, ".gitignore"))).to eq("shared.txt\n")
              expect(File.symlink?(File.join(wt_path, "shared.txt"))).to be(true)
              expect(fake.invocations).to include(
                new_window_argv(root, "feat"),
                select_window_argv("feat")
              )
            end
          end
        end
      end

      describe "#open_selected" do
        it "switches to the window of a worktree that has one" do
          app = build_app([], root: scripted_root)
          app.entries = [status("feat", has_window: true)]
          with_fake_cmd do |fake|
            script_refresh(
              fake,
              scripted_root,
              windows: "feat\n"
            )
            fake.script(select_window_argv("feat"))

            app.open_selected

            aggregate_failures do
              expect(fake.invocations).to include(select_window_argv("feat"))
              expect(fake.invocations).not_to include(new_window_argv(scripted_root, "feat"))
            end
          end
        end

        it "creates a bare window for a worktree without one" do
          app = build_app(%w[feat], root: scripted_root)
          with_fake_cmd do |fake|
            script_bare_window(fake, scripted_root, "feat")
            script_refresh(
              fake,
              scripted_root,
              windows: "feat\n"
            )

            app.open_selected

            aggregate_failures do
              expect(app.error).to be_nil
              expect(fake.invocations).to include(new_window_argv(scripted_root, "feat"))
            end
          end
        end

        it "records the error when the window selection fails" do
          app = build_app([], root: scripted_root)
          app.entries = [status("feat", has_window: true)]
          with_fake_cmd do |fake|
            script_refresh(
              fake,
              scripted_root,
              windows: "feat\n"
            )
            fake.script(
              select_window_argv("feat"),
              stderr: "no window",
              status: 1
            )

            app.open_selected

            expect(app.error).to eq("tmux failed: no window")
          end
        end

        it "records the error and stops when the window creation fails" do
          app = build_app(%w[feat], root: scripted_root)
          with_fake_cmd do |fake|
            fake.script(["tmux", "-V"], stdout: "tmux 3.4\n")
            fake.script(["tmux", "has-session", "-t", "test"])
            fake.script(
              new_window_argv(scripted_root, "feat"),
              stderr: "boom",
              status: 1
            )

            app.open_selected

            aggregate_failures do
              expect(app.error).to eq("tmux failed: boom")
              expect(fake.invocations).not_to include(list_windows_argv)
            end
          end
        end

        it "does nothing on an empty list" do
          app = build_app([], root: scripted_root)
          with_fake_cmd do |fake|
            app.open_selected

            expect(fake.invocations).to be_empty
          end
        end
      end

      describe "#close_selected" do
        it "kills the worktree's window and refreshes" do
          app = build_app([], root: scripted_root)
          app.entries = [status("feat", has_window: true)]
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv)
            fake.script(kill_window_argv("feat"))
            script_refresh(fake, scripted_root)

            app.close_selected

            aggregate_failures do
              expect(fake.invocations).to include(kill_window_argv("feat"))
              expect(app.error).to be_nil
            end
          end
        end

        it "does nothing without a window or borrowed pane" do
          app = build_app(%w[feat], root: scripted_root)
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv)

            app.close_selected

            expect(fake.invocations).not_to include(kill_window_argv("feat"))
          end
        end

        it "returns a hub-borrowed agent pane before the kill" do
          app = build_app(%w[feat], root: scripted_root)
          join_argv = ["tmux", "join-pane", "-h", "-d", "-s", "%5", "-t", "test:feat", "-l", "50%"]
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv, stdout: "%5\ttest\tfeat\n")
            fake.script(list_windows_argv, stdout: "feat\n")
            fake.script(join_argv)
            fake.script(["tmux", "set-option", "-p", "-u", "-t", "%5", "@orn_home_session"])
            fake.script(["tmux", "set-option", "-p", "-u", "-t", "%5", "@orn_home_window"])
            fake.script(kill_window_argv("feat"))
            fake.script(worktree_list_argv(scripted_root))

            app.close_selected

            expect(fake.invocations).to include(
              join_argv,
              kill_window_argv("feat")
            )
          end
        end

        it "records the error when the window kill fails" do
          app = build_app([], root: scripted_root)
          app.entries = [status("feat", has_window: true)]
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv)
            fake.script(
              kill_window_argv("feat"),
              stderr: "no window",
              status: 1
            )

            app.close_selected

            expect(app.error).to eq("tmux failed: no window")
          end
        end

        it "does nothing on an empty list" do
          app = build_app([], root: scripted_root)
          with_fake_cmd do |fake|
            app.close_selected

            expect(fake.invocations).to be_empty
          end
        end
      end

      describe "#confirm_remove" do
        def remove_argv(root, branch)
          git_argv(
            root,
            "worktree",
            "remove",
            "--force",
            File.join(root, branch)
          )
        end

        it "does nothing outside confirm-remove mode" do
          app = build_app(%w[feat], root: scripted_root)
          with_fake_cmd do |fake|
            app.confirm_remove

            expect(fake.invocations).to be_empty
          end
        end

        it "removes the worktree of a branch without a window" do
          app = build_app(%w[feat], root: scripted_root)
          app.start_remove
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv)
            fake.script(list_windows_argv)
            fake.script(remove_argv(scripted_root, "feat"))
            fake.script(worktree_list_argv(scripted_root))

            app.confirm_remove

            aggregate_failures do
              expect(fake.invocations).to include(remove_argv(scripted_root, "feat"))
              expect(fake.invocations).not_to include(kill_window_argv("feat"))
              expect(app.mode).to eq(Mode.normal)
            end
          end
        end

        it "kills the window before removing the worktree" do
          app = build_app(%w[feat], root: scripted_root)
          app.start_remove
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv)
            fake.script(list_windows_argv, stdout: "feat\n")
            fake.script(kill_window_argv("feat"))
            fake.script(remove_argv(scripted_root, "feat"))
            fake.script(worktree_list_argv(scripted_root))

            app.confirm_remove

            expect(fake.invocations).to include(
              kill_window_argv("feat"),
              remove_argv(scripted_root, "feat")
            )
          end
        end

        it "stops before the removal when the window kill fails" do
          app = build_app(%w[feat], root: scripted_root)
          app.start_remove
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv)
            fake.script(list_windows_argv, stdout: "feat\n")
            fake.script(
              kill_window_argv("feat"),
              stderr: "boom",
              status: 1
            )

            app.confirm_remove

            aggregate_failures do
              expect(app.error).to eq("tmux failed: boom")
              expect(fake.invocations).not_to include(remove_argv(scripted_root, "feat"))
            end
          end
        end

        it "records the error when the worktree removal fails" do
          app = build_app(%w[feat], root: scripted_root)
          app.start_remove
          with_fake_cmd do |fake|
            fake.script(borrowed_panes_argv)
            fake.script(list_windows_argv)
            fake.script(
              remove_argv(scripted_root, "feat"),
              stderr: "locked",
              status: 1
            )

            app.confirm_remove

            expect(app.error).to eq("git failed: locked")
          end
        end
      end
    end
  end
end
