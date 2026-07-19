# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe RepoStatus do
      def list_sessions_argv
        [
          "tmux",
          "list-sessions",
          "-F",
          "\#{session_name}\t\#{session_activity}"
        ]
      end

      def list_windows_argv(session = "api")
        [
          "tmux",
          "list-windows",
          "-t",
          "#{session}:",
          "-F",
          "\#{window_name}"
        ]
      end

      def entry(name)
        RepoEntry.new(
          display_name: name,
          root: "/tmp/nonexistent-#{name}",
          healthy: true,
          session_name: name,
          base_branch: "main"
        )
      end

      def pane(id, session:, window: "main", command: "zsh", pid: 1, title: "")
        Orn::Tmux::PaneMetadata.new(
          session_name: session,
          window_name: window,
          pane_pid: pid,
          pane_title: title,
          pane_current_command: command,
          pane_id: id
        )
      end

      def tab(root, branch, pane_id)
        Hub::Tab.new(
          root: root,
          session: "api",
          base_branch: "main",
          branch: branch,
          pane_id: pane_id
        )
      end

      def refresh(repos, tab: nil, all_panes: [])
        described_class.refresh(
          Orn::OutputMode.quiet,
          repos,
          tab,
          all_panes
        )
      end

      describe ".refresh" do
        it "marks a live session and its windowed worktrees" do
          repo = entry("api").with(
            worktrees: [WorktreeRow.new(branch: "main"), WorktreeRow.new(branch: "feat")]
          )

          refreshed = nil
          with_fake_cmd do |fake|
            fake.script(list_sessions_argv, stdout: "api\t123\n")
            fake.script(list_windows_argv, stdout: "orn\nmain\n")
            refreshed = refresh([repo]).first
          end

          aggregate_failures do
            expect(refreshed.session_alive).to be(true)
            expect(refreshed.session_activity).to eq(123)
            expect(refreshed.window_count).to eq(2)
            expect(refreshed.worktrees[0].has_window).to be(true)
            expect(refreshed.worktrees[1].has_window).to be(false)
            expect(refreshed.aggregate_agent_state).to be_nil
          end
        end

        def live_repo
          entry("api").with(
            session_alive: true,
            session_activity: 99,
            window_count: 3,
            aggregate_agent_state: :working,
            worktrees: [
              WorktreeRow.new(
                branch: "main",
                has_window: true,
                agent: Orn::Detect::PaneAgentState.new(
                  agent: :claude,
                  state: :working
                ),
                sandboxed: true
              )
            ]
          )
        end

        it "clears live state when the session is gone" do
          refreshed = nil
          with_fake_cmd do |fake|
            fake.script(list_sessions_argv, stdout: "")
            refreshed = refresh([live_repo]).first
          end

          worktree = refreshed.worktrees[0]
          aggregate_failures do
            expect(refreshed.session_alive).to be(false)
            expect(refreshed.session_activity).to be_nil
            expect(refreshed.window_count).to eq(0)
            expect(refreshed.aggregate_agent_state).to be_nil
            expect(worktree.has_window).to be(false)
            expect(worktree.agent).to be_nil
            expect(worktree.sandboxed).to be(false)
          end
        end

        it "treats a failed session listing as no sessions" do
          repo = entry("api").with(session_alive: true)

          refreshed = nil
          with_fake_cmd do |fake|
            fake.script(list_sessions_argv, status: 1)
            refreshed = refresh([repo]).first
          end

          expect(refreshed.session_alive).to be(false)
        end

        it "treats a missing tmux binary as no sessions" do
          repo = entry("api").with(session_alive: true)

          refreshed = nil
          with_fake_cmd do |fake|
            fake.script_missing(list_sessions_argv)
            refreshed = refresh([repo]).first
          end

          expect(refreshed.session_alive).to be(false)
        end

        it "flags a worktree sandboxed when a pane in its window runs a container command" do
          stub_host_os("linux")
          repo = entry("api").with(
            worktrees: [
              WorktreeRow.new(branch: "main"),
              WorktreeRow.new(branch: "feat")
            ]
          )
          # A pid that cannot exist, so agent detection finds no foreground job
          # and only the pane command matters.
          container_pane = pane(
            "%1",
            session: "api",
            window: "feat",
            command: "docker",
            pid: 4_999_999_999
          )
          shell_pane = pane(
            "%2",
            session: "api",
            window: "main",
            command: "zsh",
            pid: 4_999_999_999
          )

          refreshed = nil
          with_fake_cmd do |fake|
            fake.script(list_sessions_argv, stdout: "api\t123\n")
            fake.script(list_windows_argv, stdout: "main\nfeat\n")
            refreshed = refresh(
              [repo],
              all_panes: [
                container_pane,
                shell_pane
              ]
            ).first
          end

          aggregate_failures do
            expect(refreshed.worktrees[1].sandboxed).to be(true)
            expect(refreshed.worktrees[0].sandboxed).to be(false)
          end
        end

        it "fills git stats for an expanded repo" do
          repo = entry("api").with(
            expanded: true,
            worktrees: [WorktreeRow.new(branch: "feat")]
          )
          worktree_path = "/tmp/nonexistent-api/feat"

          refreshed = nil
          with_fake_cmd do |fake|
            fake.script(list_sessions_argv, stdout: "")
            fake.script(
              [
                "git",
                "-C",
                worktree_path,
                "status",
                "--porcelain"
              ],
              stdout: " M file.txt\n"
            )
            fake.script(
              [
                "git",
                "-C",
                worktree_path,
                "rev-list",
                "--left-right",
                "--count",
                "feat...main"
              ],
              stdout: "1\t2\n"
            )
            refreshed = refresh([repo]).first
          end

          worktree = refreshed.worktrees[0]
          aggregate_failures do
            expect(worktree.dirty).to be(true)
            expect(worktree.ahead_behind).to eq([1, 2])
          end
        end

        it "attributes the borrowed pane's agent to its home worktree branch" do
          repo = entry("api").with(
            worktrees: [
              WorktreeRow.new(branch: "main"),
              WorktreeRow.new(branch: "feat")
            ]
          )
          # The braille spinner in the OSC title marks Claude as working, so
          # detection settles without capturing the pane's screen.
          hub_pane = pane(
            "%5",
            session: "orn",
            window: "orn",
            command: "claude",
            title: "⠋ claude"
          )

          refreshed = nil
          with_fake_cmd do |fake|
            fake.script(list_sessions_argv, stdout: "")
            refreshed = refresh(
              [repo],
              tab: tab(repo.root, "feat", "%5"),
              all_panes: [hub_pane]
            ).first
          end

          feat_worktree = refreshed.worktrees[1]
          aggregate_failures do
            expect(refreshed.session_alive).to be(false)
            expect(refreshed.aggregate_agent_state).to eq(:working)
            expect(feat_worktree.agent).to eq(
              Orn::Detect::PaneAgentState.new(
                agent: :claude,
                state: :working
              )
            )
            expect(feat_worktree.sandboxed).to be(false)
            expect(refreshed.worktrees[0].agent).to be_nil
          end
        end
      end

      describe ".borrowed_pane_for_repo" do
        it "remaps the borrowed pane to its home session and branch" do
          repo = entry("api")
          hub_pane = pane(
            "%5",
            session: "orn",
            window: "orn"
          )

          borrowed = described_class.borrowed_pane_for_repo(
            tab(repo.root, "feat", "%5"),
            repo,
            [hub_pane]
          )

          aggregate_failures do
            expect(borrowed.session_name).to eq("api")
            expect(borrowed.window_name).to eq("feat")
            expect(borrowed.pane_id).to eq("%5")
          end
        end

        it "is nil when the tab belongs to another repo" do
          repo = entry("api")

          borrowed = described_class.borrowed_pane_for_repo(
            tab("/tmp/elsewhere", "feat", "%5"),
            repo,
            [pane("%5", session: "orn")]
          )

          expect(borrowed).to be_nil
        end

        it "is nil when the pane is gone from the listing" do
          repo = entry("api")

          borrowed = described_class.borrowed_pane_for_repo(
            tab(repo.root, "feat", "%5"),
            repo,
            []
          )

          expect(borrowed).to be_nil
        end
      end

      describe ".session_panes" do
        it "replaces the repo's original pane with the borrowed one" do
          repo = entry("api")
          own = pane("%6", session: "api")
          original = pane("%5", session: "api")
          other = pane("%7", session: "other")
          borrowed = pane(
            "%5",
            session: "api",
            window: "feat"
          )

          panes = described_class.session_panes(repo, [original, own, other], borrowed)

          expect(panes).to eq([own, borrowed])
        end

        it "keeps only the repo's own panes without a borrowed pane" do
          repo = entry("api")
          own = pane("%6", session: "api")

          panes = described_class.session_panes(repo, [own, pane("%7", session: "other")], nil)

          expect(panes).to eq([own])
        end
      end

      describe ".aggregate_state" do
        def states(*pairs)
          pairs.each_with_index.to_h do |(agent, state), i|
            [
              "win#{i}",
              Orn::Detect::PaneAgentState.new(
                agent: agent,
                state: state
              )
            ]
          end
        end

        it "ranks blocked over working" do
          expect(described_class.aggregate_state(states(%i[claude blocked], %i[claude working]))).to eq(:blocked)
        end

        it "ranks working over idle" do
          expect(described_class.aggregate_state(states(%i[claude working], %i[claude idle]))).to eq(:working)
        end

        it "returns idle when all agents are idle" do
          expect(described_class.aggregate_state(states(%i[claude idle], %i[claude idle]))).to eq(:idle)
        end

        it "returns nil when no pane hosts an agent" do
          expect(described_class.aggregate_state(states([nil, :unknown]))).to be_nil
        end

        it "returns nil for an empty set" do
          expect(described_class.aggregate_state({})).to be_nil
        end
      end
    end
  end
end
