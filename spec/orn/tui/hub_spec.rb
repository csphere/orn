# frozen_string_literal: true

require "tmpdir"

module Orn
  module TUI
    RSpec.describe Hub do
      let(:client) { FakeTmuxClient.new }
      let(:hub) { described_class.new(client: client) }

      def unset_home_calls(pane_id)
        [
          [:unset_pane_option, pane_id, "@orn_home_session"],
          [:unset_pane_option, pane_id, "@orn_home_window"]
        ]
      end

      def agent_pane(window, pane_id, command = "zsh")
        Orn::Tmux::PaneMetadata.new(
          session_name: nil,
          window_name: window,
          pane_pid: 123,
          pane_title: "title",
          pane_current_command: command,
          pane_id: pane_id
        )
      end

      def build_tab
        described_class::Tab.new(
          root: "/tmp/repo",
          session: "repo",
          base_branch: "main",
          branch: "feat",
          pane_id: "%5"
        )
      end

      def borrowed_pane(pane_id = "%5", window = "feat")
        Orn::Tmux::BorrowedPane.new(
          pane_id: pane_id,
          home_session: "repo",
          home_window: window
        )
      end

      describe "#open_tab" do
        def open_feat_tab(root: "/tmp/repo")
          hub.open_tab(
            root: root,
            session: "repo",
            base_branch: "main",
            branch: "feat",
            hub_pane: "%0"
          )
        end

        it "borrows the branch's agent pane into the hub window" do
          client.windows = { "repo" => %w[main feat] }
          client.panes = { "repo" => [agent_pane("feat", "%5", "claude")] }

          tab = open_feat_tab

          aggregate_failures do
            expect(tab).to have_attributes(
              root: "/tmp/repo",
              session: "repo",
              base_branch: "main",
              branch: "feat",
              pane_id: "%5"
            )
            expect(client.calls).to eq(
              [
                [:window_exists?, "repo", "feat"],
                [:list_panes_metadata, "repo"],
                [:set_pane_option, "%5", "@orn_home_session", "repo"],
                [:set_pane_option, "%5", "@orn_home_window", "feat"],
                [:join_pane, "%5", "%0", 67, true],
                [:resize_pane_width, "%0", 33]
              ]
            )
          end
        end

        it "raises when the branch window has no pane" do
          client.windows = { "repo" => ["feat"] }
          client.panes = { "repo" => [agent_pane("main", "%6")] }

          expect { open_feat_tab }.to raise_error(
            Orn::Error,
            "no pane found for 'feat' in session 'repo'"
          )
        end

        # The partial state FakeHub cannot reach: the window was created, then
        # the pane lookup came up empty and open_tab raised. The created
        # window is visible in the recorded open call.
        it "raises after creating the window when its agent pane never appears" do
          Dir.mktmpdir do |tmp_dir|
            root = File.join(tmp_dir, "repo")
            Dir.mkdir(root)
            client.windows = { "repo" => [] }

            with_fake_cmd do |fake|
              fake.script(%w[sbx inspect repo-feat], status: 1)

              expect { open_feat_tab(root: root) }.to raise_error(
                Orn::Error,
                "no pane found for 'feat' in session 'repo'"
              )
            end

            aggregate_failures do
              expect(client.calls).to include([:open_window_non_interactive, "feat"])
              expect(client.windows["repo"]).to include("feat")
            end
          end
        end
      end

      describe "#ensure_window" do
        # A real project directory named "repo" with no config file, isolated
        # from the user's global config and approval data, so the session and
        # sandbox names derive from the directory name.
        def with_project_root
          Dir.mktmpdir do |tmp_dir|
            root = File.join(tmp_dir, "repo")
            Dir.mkdir(root)
            ENV["XDG_CONFIG_HOME"] = File.join(tmp_dir, "xdg-config")
            ENV["XDG_DATA_HOME"] = File.join(tmp_dir, "xdg-data")
            yield root
          end
        end

        it "leaves an already open window alone" do
          client.windows = { "repo" => ["feat"] }

          hub.ensure_window(
            "/tmp/repo",
            "feat",
            "repo"
          )

          expect(client.calls).to eq([[:window_exists?, "repo", "feat"]])
        end

        it "refuses a sandboxed branch whose window is closed" do
          with_project_root do |root|
            client.windows = { "repo" => ["main"] }

            with_fake_cmd do |fake|
              fake.script(%w[sbx inspect repo-feat], stdout: "{}")

              expect do
                hub.ensure_window(
                  root,
                  "feat",
                  "repo"
                )
              end.to raise_error(
                Orn::Error,
                "'feat' uses sandbox 'repo-feat' and its window is closed; run 'orn switch feat' to reopen it"
              )
            end

            expect(client.count(:open_window_non_interactive)).to eq(0)
          end
        end

        it "opens the worktree window for a plain branch" do
          with_project_root do |root|
            client.windows = { "repo" => ["main"] }

            with_fake_cmd do |fake|
              fake.script(%w[sbx inspect repo-feat], status: 1)

              hub.ensure_window(
                root,
                "feat",
                "repo"
              )
            end

            expect(client.calls).to eq(
              [
                [:window_exists?, "repo", "feat"],
                [:open_window_non_interactive, "feat"]
              ]
            )
          end
        end
      end

      describe "#show_tab" do
        it "tags the pane with its home and splits it beside the sidebar" do
          hub.show_tab(build_tab, "%0")

          expect(client.calls).to eq(
            [
              [:set_pane_option, "%5", "@orn_home_session", "repo"],
              [:set_pane_option, "%5", "@orn_home_window", "feat"],
              [:join_pane, "%5", "%0", 67, true],
              [:resize_pane_width, "%0", 33]
            ]
          )
        end
      end

      describe "#hide_tab" do
        it "returns the pane home, clears its tags, and reorders the windows" do
          client.windows = { "repo" => ["feat"] }

          hub.hide_tab(build_tab)

          expect(client.calls).to eq(
            [
              [:window_exists?, "repo", "feat"],
              [:join_pane, "%5", "repo:feat", 50, false],
              *unset_home_calls("%5"),
              [:reorder_windows, "repo", "main"]
            ]
          )
        end
      end

      describe "#return_pane_home" do
        it "joins the pane back into its still-open home window" do
          client.windows = { "repo" => %w[feat main] }

          hub.return_pane_home(borrowed_pane)

          expect(client.calls).to eq(
            [
              [:window_exists?, "repo", "feat"],
              [:join_pane, "%5", "repo:feat", 50, false],
              *unset_home_calls("%5")
            ]
          )
        end

        it "breaks the pane out into a new window when its window is gone" do
          client.windows = { "repo" => ["main"] }
          client.sessions = ["repo"]

          hub.return_pane_home(borrowed_pane)

          expect(client.calls).to eq(
            [
              [:window_exists?, "repo", "feat"],
              [:session_exists?, "repo"],
              [:break_pane, "%5", "repo", "feat"],
              *unset_home_calls("%5")
            ]
          )
        end

        it "recreates the session when borrowing the pane emptied it" do
          hub.return_pane_home(borrowed_pane)

          expect(client.calls).to eq(
            [
              [:window_exists?, "repo", "feat"],
              [:session_exists?, "repo"],
              [:recreate_session_with_pane, "%5", "repo", "feat"],
              *unset_home_calls("%5")
            ]
          )
        end
      end

      describe "#reconcile" do
        it "keeps returning panes after one pane fails" do
          client.borrowed = [
            borrowed_pane("%1", "gone"),
            borrowed_pane("%2", "alive")
          ]
          client.windows = { "repo" => ["alive"] }
          client.sessions = ["repo"]
          client.fail_on = [:break_pane]

          hub.reconcile

          aggregate_failures do
            expect(client.calls).to include([:break_pane, "%1", "repo", "gone"])
            expect(client.calls).to include([:join_pane, "%2", "repo:alive", 50, false])
            expect(client.calls).to include(*unset_home_calls("%2"))
            expect(client.calls).not_to include([:unset_pane_option, "%1", "@orn_home_session"])
          end
        end
      end

      describe "#return_borrowed_for_branch" do
        it "returns the branch's borrowed pane home and reports true" do
          client.borrowed = [borrowed_pane]
          client.windows = { "repo" => ["feat"] }

          returned = hub.return_borrowed_for_branch("repo", "feat")

          aggregate_failures do
            expect(returned).to be(true)
            expect(client.calls).to include([:join_pane, "%5", "repo:feat", 50, false])
          end
        end

        it "reports false when no pane is borrowed for the branch" do
          client.borrowed = [borrowed_pane("%5", "other")]

          returned = hub.return_borrowed_for_branch("repo", "feat")

          aggregate_failures do
            expect(returned).to be(false)
            expect(client.calls).to eq([[:list_borrowed_panes]])
          end
        end

        it "reports false when the pane cannot be returned" do
          client.borrowed = [borrowed_pane]
          client.windows = { "repo" => ["feat"] }
          client.fail_on = [:join_pane]

          returned = hub.return_borrowed_for_branch("repo", "feat")

          expect(returned).to be(false)
        end
      end

      describe "#install_bindings" do
        it "guards the focus and cycle keys to the hub window" do
          condition = Orn::Tmux.window_guard_condition("orn", "orn")

          hub.install_bindings(
            "orn",
            "orn",
            "%0",
            "%5"
          )

          expect(client.calls).to eq(
            [
              [:bind_key_guarded, "M-o", condition, "select-pane -t %0"],
              [:bind_key_guarded, "M-i", condition, "select-pane -t %5"],
              [:bind_key_guarded, "M-n", condition, "send-keys -t %0 n"],
              [:bind_key_guarded, "M-p", condition, "send-keys -t %0 p"]
            ]
          )
        end
      end

      describe "#remove_bindings" do
        it "unbinds every hub key even when the unbinds fail" do
          client.fail_on = [:unbind_key]

          hub.remove_bindings

          expect(client.calls).to eq(
            [
              [:unbind_key, "M-o"],
              [:unbind_key, "M-i"],
              [:unbind_key, "M-n"],
              [:unbind_key, "M-p"]
            ]
          )
        end
      end
    end
  end
end
