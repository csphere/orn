# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module Orn
  module TUI
    RSpec.describe RepoDiscovery do
      def entry(name)
        RepoEntry.new(
          display_name: name,
          root: "/tmp/nonexistent-#{name}",
          healthy: true,
          session_name: "nonexistent",
          base_branch: "main"
        )
      end

      def discover(root, state: State.new)
        described_class.discover(Orn::OutputMode.quiet, config_for(root), state)
      end

      def config_for(root)
        Orn::Config::GlobalTuiConfig.new(
          session: "orn",
          scan_roots: [root],
          scan_depth: 3
        )
      end

      def make_bare(root, name, head: "ref: refs/heads/main\n")
        bare = File.join(root, name, ".bare")
        FileUtils.mkdir_p(bare)
        File.write(File.join(bare, "HEAD"), head) if head
      end

      describe ".healthy?" do
        around { |example| Dir.mktmpdir { |dir| example.metadata[:dir] = dir and example.run } }

        it "is true for a bare repo with a readable HEAD" do |example|
          bare = File.join(example.metadata[:dir], ".bare")
          FileUtils.mkdir_p(bare)
          File.write(File.join(bare, "HEAD"), "ref: refs/heads/main\n")

          expect(described_class.healthy?(example.metadata[:dir])).to be(true)
        end

        it "is false when HEAD is missing" do |example|
          FileUtils.mkdir_p(File.join(example.metadata[:dir], ".bare"))

          expect(described_class.healthy?(example.metadata[:dir])).to be(false)
        end

        it "is false when there is no bare dir" do |example|
          expect(described_class.healthy?(example.metadata[:dir])).to be(false)
        end
      end

      describe ".discover", :real_cmd do
        around { |example| Dir.mktmpdir { |dir| example.metadata[:dir] = dir and example.run } }

        it "finds bare projects and names them relative to the scan root" do |example|
          root = example.metadata[:dir]
          make_bare(root, "org/project-a")
          make_bare(root, "org/project-b")

          names = discover(root).map(&:display_name)

          aggregate_failures do
            expect(names).to include("org/project-a")
            expect(names).to include("org/project-b")
          end
        end

        it "marks a repo without HEAD as unhealthy" do |example|
          root = example.metadata[:dir]
          make_bare(root, "broken", head: nil)

          repos = discover(root)

          aggregate_failures do
            expect(repos.length).to eq(1)
            expect(repos[0].healthy).to be(false)
          end
        end

        it "caches the session name from the root basename" do |example|
          root = example.metadata[:dir]
          make_bare(root, "my-project")

          repos = discover(root)

          expect(repos[0].session_name).to eq("my-project")
        end

        it "caches the session name from config" do |example|
          root = example.metadata[:dir]
          make_bare(root, "my-project")
          FileUtils.mkdir_p(
            File.join(root, "my-project", ".orn")
          )
          File.write(
            File.join(
              root,
              "my-project",
              ".orn",
              "config.yaml"
            ),
            "tmux:\n  session: custom-name\n"
          )

          repos = discover(root)

          expect(repos[0].session_name).to eq("custom-name")
        end

        it "sorts unseen repos alphabetically" do |example|
          root = example.metadata[:dir]
          %w[zebra alpha middle].each { |name| make_bare(root, name) }

          repos = discover(root)
          described_class.sort_entries(repos)

          expect(repos.map(&:display_name)).to eq(%w[alpha middle zebra])
        end

        it "applies the persisted MRU timestamp to a discovered repo" do |example|
          root = example.metadata[:dir]
          make_bare(root, "seen")
          state = State.new(mru: { File.join(root, "seen") => "2026-06-27T14:30:00Z" })

          repos = discover(root, state: state)

          expect(repos[0].mru_timestamp).to eq("2026-06-27T14:30:00Z")
        end

        it "applies the persisted expanded state to a discovered repo" do |example|
          root = example.metadata[:dir]
          make_bare(root, "open")
          make_bare(root, "closed")
          state = State.new(expanded: [File.join(root, "open")])

          expanded = discover(root, state: state).to_h { |repo| [repo.display_name, repo.expanded] }

          expect(expanded).to eq(
            "open" => true,
            "closed" => false
          )
        end

        it "prunes persisted state for repos no longer discovered" do |example|
          root = example.metadata[:dir]
          make_bare(root, "kept")
          kept_root = File.join(root, "kept")
          state = State.new(
            mru: {
              kept_root => "2026-06-27T14:30:00Z",
              "/gone" => "2026-06-01T00:00:00Z"
            },
            expanded: ["/gone"]
          )

          discover(root, state: state)

          aggregate_failures do
            expect(state.mru.keys).to eq([kept_root])
            expect(state.expanded).to be_empty
          end
        end
      end

      describe ".discover with scripted scan output" do
        def find_argv(root)
          [
            "find",
            root,
            "-maxdepth",
            "3",
            "-name",
            ".bare",
            "-type",
            "d"
          ]
        end

        it "returns no repos when the scan command fails" do
          with_fake_cmd do |fake|
            fake.script(find_argv("/scan"), status: 1)

            expect(discover("/scan")).to be_empty
          end
        end

        it "returns no repos when find is not installed" do
          with_fake_cmd do |fake|
            fake.script_missing(find_argv("/scan"))

            expect(discover("/scan")).to be_empty
          end
        end

        it "builds entries from the scan output, skipping blank lines" do
          with_fake_cmd do |fake|
            fake.script(find_argv("/scan"), stdout: "/scan/org/proj/.bare\n\n")
            fake.script(
              [
                "git",
                "-C",
                "/scan/org/proj",
                "worktree",
                "list",
                "--porcelain"
              ],
              status: 1
            )

            repos = discover("/scan")

            aggregate_failures do
              expect(repos.map(&:display_name)).to eq(["org/proj"])
              expect(repos[0].root).to eq("/scan/org/proj")
              expect(repos[0].worktrees).to be_empty
            end
          end
        end
      end

      describe ".disambiguate_names" do
        it "prefixes colliding names with the scan-root basename" do
          repos = [
            RepoEntry.new(
              display_name: "orn",
              root: "/home/user/dev/orn",
              healthy: true,
              session_name: "orn",
              base_branch: "main"
            ),
            RepoEntry.new(
              display_name: "orn",
              root: "/home/user/work/orn",
              healthy: true,
              session_name: "orn",
              base_branch: "main"
            )
          ]

          renamed = described_class.disambiguate_names(["/home/user/dev", "/home/user/work"], repos)

          aggregate_failures do
            expect(renamed[0].display_name).to eq("dev/orn")
            expect(renamed[1].display_name).to eq("work/orn")
          end
        end

        it "leaves unique names untouched" do
          repos = [
            RepoEntry.new(
              display_name: "alpha",
              root: "/home/user/dev/alpha",
              healthy: true,
              session_name: "alpha",
              base_branch: "main"
            ),
            RepoEntry.new(
              display_name: "beta",
              root: "/home/user/work/beta",
              healthy: true,
              session_name: "beta",
              base_branch: "main"
            )
          ]

          renamed = described_class.disambiguate_names(["/home/user/dev", "/home/user/work"], repos)

          expect(renamed.map(&:display_name)).to eq(%w[alpha beta])
        end
      end

      describe ".sort_entries" do
        def live(name, activity)
          entry(name).with(
            session_alive: true,
            session_activity: activity
          )
        end

        def mru(name, timestamp)
          entry(name).with(mru_timestamp: timestamp)
        end

        it "orders live sessions before mru before unseen, with the right sub-order" do
          repos = [entry("unseen-z"), live("live", 100), entry("unseen-a"), mru("mru", "2026-06-27T14:30:00Z")]

          described_class.sort_entries(repos)

          expect(repos.map(&:display_name)).to eq(%w[live mru unseen-a unseen-z])
        end

        it "orders live sessions by activity descending" do
          repos = [live("older", 100), live("newer", 200)]

          described_class.sort_entries(repos)

          expect(repos.map(&:display_name)).to eq(%w[newer older])
        end

        it "orders mru repos by timestamp descending" do
          repos = [mru("older-mru", "2026-06-26T09:00:00Z"), mru("newer-mru", "2026-06-27T14:30:00Z")]

          described_class.sort_entries(repos)

          expect(repos.map(&:display_name)).to eq(%w[newer-mru older-mru])
        end
      end

      describe ".list_worktree_rows", :real_cmd do
        it "is empty for a nonexistent repo" do
          rows = described_class.list_worktree_rows(Orn::OutputMode.quiet, "/tmp/nonexistent-orn", "main")

          expect(rows).to be_empty
        end
      end

      describe ".sort_branches_base_first" do
        it "puts the base branch first, then alphabetical" do
          branches = %w[zeta main alpha]
          described_class.sort_branches_base_first(branches, "main")

          expect(branches).to eq(%w[main alpha zeta])
        end

        it "is alphabetical when the base is absent" do
          branches = %w[zeta alpha]
          described_class.sort_branches_base_first(branches, "main")

          expect(branches).to eq(%w[alpha zeta])
        end
      end
    end
  end
end
