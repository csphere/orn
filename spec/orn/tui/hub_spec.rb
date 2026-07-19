# frozen_string_literal: true

require "tmpdir"

module Orn
  module TUI
    RSpec.describe Hub do
      let(:output_mode) { Orn::OutputMode.quiet }

      def list_windows_argv(session)
        ["tmux", "list-windows", "-t", "#{session}:", "-F", "\#{window_name}"]
      end

      def list_panes_argv(session)
        pane_format = "\#{window_name}\t\#{pane_pid}\t\#{pane_current_command}\t\#{pane_id}\t\#{pane_title}"
        ["tmux", "list-panes", "-s", "-t", "#{session}:", "-F", pane_format]
      end

      def borrowed_list_argv
        ["tmux", "list-panes", "-a", "-F", "\#{pane_id}\t\#{@orn_home_session}\t\#{@orn_home_window}"]
      end

      def has_session_argv(session)
        ["tmux", "has-session", "-t", session]
      end

      def set_option_argv(pane_id, option_name, value)
        ["tmux", "set-option", "-p", "-t", pane_id, option_name, value]
      end

      def unset_option_argv(pane_id, option_name)
        ["tmux", "set-option", "-p", "-u", "-t", pane_id, option_name]
      end

      def unset_home_argvs(pane_id)
        [
          unset_option_argv(pane_id, "@orn_home_session"),
          unset_option_argv(pane_id, "@orn_home_window")
        ]
      end

      # Borrowing into the hub window: focused join, agent gets 67% of the width.
      def hub_join_argv(pane_id, hub_pane)
        ["tmux", "join-pane", "-h", "-s", pane_id, "-t", hub_pane, "-l", "67%"]
      end

      # Returning to the home window: detached join, even 50% split.
      def home_join_argv(pane_id, target)
        ["tmux", "join-pane", "-h", "-d", "-s", pane_id, "-t", target, "-l", "50%"]
      end

      def break_pane_argv(pane_id, session, window)
        ["tmux", "break-pane", "-d", "-s", pane_id, "-n", window, "-t", "#{session}:"]
      end

      def resize_argv(pane_id)
        ["tmux", "resize-pane", "-t", pane_id, "-x", "33%"]
      end

      def pane_line(window, pane_id, command = "zsh")
        "#{window}\t123\t#{command}\t#{pane_id}\ttitle\n"
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

      def borrowed_pane
        Orn::Tmux::BorrowedPane.new(
          pane_id: "%5",
          home_session: "repo",
          home_window: "feat"
        )
      end

      describe ".open_tab" do
        def open_feat_tab
          described_class.open_tab(
            output_mode,
            root: "/tmp/repo",
            session: "repo",
            base_branch: "main",
            branch: "feat",
            hub_pane: "%0"
          )
        end

        it "borrows the branch's agent pane into the hub window" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "main\nfeat\n")
            fake.script(list_panes_argv("repo"), stdout: pane_line("feat", "%5", "claude"))
            fake.script(set_option_argv("%5", "@orn_home_session", "repo"))
            fake.script(set_option_argv("%5", "@orn_home_window", "feat"))
            fake.script(hub_join_argv("%5", "%0"))
            fake.script(resize_argv("%0"))

            tab = open_feat_tab

            aggregate_failures do
              expect(tab).to have_attributes(
                root: "/tmp/repo",
                session: "repo",
                base_branch: "main",
                branch: "feat",
                pane_id: "%5"
              )
              expect(fake.invocations).to eq(
                [
                  list_windows_argv("repo"),
                  list_panes_argv("repo"),
                  set_option_argv("%5", "@orn_home_session", "repo"),
                  set_option_argv("%5", "@orn_home_window", "feat"),
                  hub_join_argv("%5", "%0"),
                  resize_argv("%0")
                ]
              )
            end
          end
        end

        it "raises when the branch window has no pane" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "feat\n")
            fake.script(list_panes_argv("repo"), stdout: pane_line("main", "%6"))

            expect { open_feat_tab }.to raise_error(
              Orn::Error,
              "no pane found for 'feat' in session 'repo'"
            )
          end
        end
      end

      describe ".ensure_window" do
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

        def new_window_argv(root)
          [
            "tmux",
            "new-window",
            "-a",
            "-P",
            "-F",
            "\#{pane_id}",
            "-t",
            "repo:",
            "-n",
            "feat",
            "-c",
            File.join(root, "feat")
          ]
        end

        def split_window_argv(target_pane, root)
          [
            "tmux",
            "split-window",
            "-h",
            "-t",
            target_pane,
            "-c",
            File.join(root, "feat"),
            "-l",
            "50%",
            "-P",
            "-F",
            "\#{pane_id}"
          ]
        end

        it "leaves an already open window alone" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "feat\n")

            described_class.ensure_window(
              output_mode,
              "/tmp/repo",
              "feat",
              "repo"
            )

            expect(fake.invocations).to eq([list_windows_argv("repo")])
          end
        end

        it "refuses a sandboxed branch whose window is closed" do
          with_project_root do |root|
            with_fake_cmd do |fake|
              fake.script(list_windows_argv("repo"), stdout: "main\n")
              fake.script(%w[sbx inspect repo-feat], stdout: "{}")

              expect do
                described_class.ensure_window(
                  output_mode,
                  root,
                  "feat",
                  "repo"
                )
              end.to raise_error(
                Orn::Error,
                "'feat' uses sandbox 'repo-feat' and its window is closed; run 'orn switch feat' to reopen it"
              )
            end
          end
        end

        def script_plain_branch_open(fake, root)
          fake.script(list_windows_argv("repo"), stdout: "main\n")
          fake.script(%w[sbx inspect repo-feat], status: 1)
          fake.script(["tmux", "-V"], stdout: "tmux 3.4\n")
          fake.script(has_session_argv("repo"))
          fake.script(new_window_argv(root), stdout: "%9\n")
          fake.script(split_window_argv("%9", root), stdout: "%10\n")
          fake.script(["tmux", "select-pane", "-t", "%9"])
          fake.script(["tmux", "select-window", "-t", "repo:feat"])
        end

        it "opens the worktree window for a plain branch" do
          with_project_root do |root|
            with_fake_cmd do |fake|
              script_plain_branch_open(fake, root)

              described_class.ensure_window(
                output_mode,
                root,
                "feat",
                "repo"
              )

              aggregate_failures do
                expect(fake.invocations).to include(new_window_argv(root))
                expect(fake.invocations).to include(split_window_argv("%9", root))
                expect(fake.invocations.last).to eq(["tmux", "select-window", "-t", "repo:feat"])
              end
            end
          end
        end
      end

      describe ".show_tab" do
        it "tags the pane with its home and splits it beside the sidebar" do
          with_fake_cmd do |fake|
            fake.script(set_option_argv("%5", "@orn_home_session", "repo"))
            fake.script(set_option_argv("%5", "@orn_home_window", "feat"))
            fake.script(hub_join_argv("%5", "%0"))
            fake.script(resize_argv("%0"))

            described_class.show_tab(
              output_mode,
              build_tab,
              "%0"
            )

            expect(fake.invocations).to eq(
              [
                set_option_argv("%5", "@orn_home_session", "repo"),
                set_option_argv("%5", "@orn_home_window", "feat"),
                hub_join_argv("%5", "%0"),
                resize_argv("%0")
              ]
            )
          end
        end
      end

      describe ".hide_tab" do
        it "returns the pane home, clears its tags, and reorders the windows" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "feat\n")
            fake.script(home_join_argv("%5", "repo:feat"))
            unset_home_argvs("%5").each { |argv| fake.script(argv) }

            described_class.hide_tab(output_mode, build_tab)

            expect(fake.invocations).to eq(
              [
                list_windows_argv("repo"),
                home_join_argv("%5", "repo:feat"),
                *unset_home_argvs("%5"),
                list_windows_argv("repo")
              ]
            )
          end
        end
      end

      describe ".return_pane_home" do
        it "joins the pane back into its still-open home window" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "feat\nmain\n")
            fake.script(home_join_argv("%5", "repo:feat"))
            unset_home_argvs("%5").each { |argv| fake.script(argv) }

            described_class.return_pane_home(output_mode, borrowed_pane)

            expect(fake.invocations).to eq(
              [
                list_windows_argv("repo"),
                home_join_argv("%5", "repo:feat"),
                *unset_home_argvs("%5")
              ]
            )
          end
        end

        it "breaks the pane out into a new window when its window is gone" do
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("repo"), stdout: "main\n")
            fake.script(has_session_argv("repo"))
            fake.script(break_pane_argv("%5", "repo", "feat"))
            unset_home_argvs("%5").each { |argv| fake.script(argv) }

            described_class.return_pane_home(output_mode, borrowed_pane)

            expect(fake.invocations).to eq(
              [
                list_windows_argv("repo"),
                has_session_argv("repo"),
                break_pane_argv("%5", "repo", "feat"),
                *unset_home_argvs("%5")
              ]
            )
          end
        end

        it "recreates the session when borrowing the pane emptied it" do
          recreate_argv = [
            "tmux",
            "new-session",
            "-d",
            "-s",
            "repo",
            "-c",
            "/tmp/wt",
            "-P",
            "-F",
            "\#{window_id}"
          ]
          pane_path_argv = ["tmux", "display-message", "-p", "-t", "%5", "\#{pane_current_path}"]
          with_fake_cmd do |fake|
            fake.script(
              list_windows_argv("repo"),
              stderr: "no such session",
              status: 1
            )
            fake.script(
              has_session_argv("repo"),
              stderr: "no such session",
              status: 1
            )
            fake.script(pane_path_argv, stdout: "/tmp/wt\n")
            fake.script(recreate_argv, stdout: "@7\n")
            fake.script(break_pane_argv("%5", "repo", "feat"))
            fake.script(["tmux", "kill-window", "-t", "@7"])
            unset_home_argvs("%5").each { |argv| fake.script(argv) }

            described_class.return_pane_home(output_mode, borrowed_pane)

            expect(fake.invocations).to eq(
              [
                list_windows_argv("repo"),
                has_session_argv("repo"),
                pane_path_argv,
                recreate_argv,
                break_pane_argv("%5", "repo", "feat"),
                ["tmux", "kill-window", "-t", "@7"],
                *unset_home_argvs("%5")
              ]
            )
          end
        end
      end

      describe ".reconcile" do
        it "keeps returning panes after one pane fails" do
          with_fake_cmd do |fake|
            fake.script(borrowed_list_argv, stdout: "%1\trepo\tone\n%2\trepo\ttwo\n")
            fake.script(list_windows_argv("repo"), stdout: "one\ntwo\n")
            fake.script(
              home_join_argv("%1", "repo:one"),
              stderr: "pane died",
              status: 1
            )
            fake.script(home_join_argv("%2", "repo:two"))
            unset_home_argvs("%2").each { |argv| fake.script(argv) }

            described_class.reconcile(output_mode)

            aggregate_failures do
              expect(fake.invocations).to include(home_join_argv("%1", "repo:one"))
              expect(fake.invocations).to include(*unset_home_argvs("%2"))
              expect(fake.invocations).not_to include(unset_option_argv("%1", "@orn_home_session"))
            end
          end
        end
      end

      describe ".return_borrowed_for_branch" do
        it "returns the branch's borrowed pane home and reports true" do
          with_fake_cmd do |fake|
            fake.script(borrowed_list_argv, stdout: "%5\trepo\tfeat\n")
            fake.script(list_windows_argv("repo"), stdout: "feat\n")
            fake.script(home_join_argv("%5", "repo:feat"))
            unset_home_argvs("%5").each { |argv| fake.script(argv) }

            returned = described_class.return_borrowed_for_branch(
              output_mode,
              "repo",
              "feat"
            )

            aggregate_failures do
              expect(returned).to be(true)
              expect(fake.invocations).to include(home_join_argv("%5", "repo:feat"))
            end
          end
        end

        it "reports false when no pane is borrowed for the branch" do
          with_fake_cmd do |fake|
            fake.script(borrowed_list_argv, stdout: "%5\trepo\tother\n")

            returned = described_class.return_borrowed_for_branch(
              output_mode,
              "repo",
              "feat"
            )

            aggregate_failures do
              expect(returned).to be(false)
              expect(fake.invocations).to eq([borrowed_list_argv])
            end
          end
        end

        it "reports false when the pane cannot be returned" do
          with_fake_cmd do |fake|
            fake.script(borrowed_list_argv, stdout: "%5\trepo\tfeat\n")
            fake.script(list_windows_argv("repo"), stdout: "feat\n")
            fake.script(
              home_join_argv("%5", "repo:feat"),
              stderr: "pane died",
              status: 1
            )

            returned = described_class.return_borrowed_for_branch(
              output_mode,
              "repo",
              "feat"
            )

            expect(returned).to be(false)
          end
        end
      end

      describe ".install_bindings" do
        def bind_key_argv(key, action)
          [
            "tmux",
            "bind-key",
            "-n",
            key,
            "if-shell",
            "-F",
            Orn::Tmux.window_guard_condition("orn", "orn"),
            action,
            "send-keys #{key}"
          ]
        end

        it "guards the focus and cycle keys to the hub window" do
          with_fake_cmd do |fake|
            expected = [
              bind_key_argv("M-o", "select-pane -t %0"),
              bind_key_argv("M-i", "select-pane -t %5"),
              bind_key_argv("M-n", "send-keys -t %0 n"),
              bind_key_argv("M-p", "send-keys -t %0 p")
            ]
            expected.each { |argv| fake.script(argv) }

            described_class.install_bindings(
              output_mode,
              "orn",
              "orn",
              "%0",
              "%5"
            )

            expect(fake.invocations).to eq(expected)
          end
        end
      end

      describe ".remove_bindings" do
        it "unbinds every hub key even when one unbind fails" do
          with_fake_cmd do |fake|
            expected = %w[M-o M-i M-n M-p].map { |key| ["tmux", "unbind-key", "-n", key] }
            fake.script(
              expected.first,
              stderr: "unknown key",
              status: 1
            )
            expected.drop(1).each { |argv| fake.script(argv) }

            described_class.remove_bindings(output_mode)

            expect(fake.invocations).to eq(expected)
          end
        end
      end
    end
  end
end
