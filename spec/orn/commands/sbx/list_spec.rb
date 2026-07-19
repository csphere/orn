# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Orn::Commands::Sbx::List do
  let(:command) { described_class.new(output_mode: Orn::OutputMode.default) }
  let(:json_command) { described_class.new(output_mode: Orn::OutputMode.quiet) }

  def project_with(config = "git:\n  base: main\n")
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx-list")), config)
  end

  # A bare project the command can discover from its root directory. The
  # configured session "proj" makes the sandbox name for branch feat
  # "proj-feat".
  def discoverable_project_root
    root = File.realpath(make_bare_project)
    File.write(File.join(root, ".orn", "config.yaml"), "tmux:\n  session: proj\n")
    isolate_global_config
    root
  end

  def worktree_list_argv(root)
    ["git", "-C", root, "worktree", "list", "--porcelain"]
  end

  def script_worktree_branches(fake_backend, root, branches)
    porcelain = branches.map do |branch|
      "worktree #{File.join(root, branch)}\nbranch refs/heads/#{branch}\n\n"
    end.join
    fake_backend.script(worktree_list_argv(root), stdout: porcelain)
  end

  def script_sandbox_listing(fake_backend, sandboxes)
    fake_backend.script(%w[which sbx])
    fake_backend.script(%w[sbx ls --json], stdout: JSON.generate(sandboxes))
  end

  def write_ports_file(root, sandbox_name, port_mappings)
    sandbox_dir = File.join(
      root,
      ".orn",
      "sandbox"
    )
    FileUtils.mkdir_p(sandbox_dir)
    File.write(File.join(sandbox_dir, "#{sandbox_name}.ports"), JSON.generate(port_mappings))
  end

  # --- Fixtures ---

  # One sandbox owned by this project (branch feat) and one that is not.
  def two_sandbox_listing
    [
      {
        "name" => "proj-feat",
        "status" => "running"
      },
      {
        "name" => "other-sbx",
        "status" => "stopped"
      }
    ]
  end

  def feat_port_mappings
    [
      {
        "host" => 3042,
        "container" => 3000
      }
    ]
  end

  def expected_populated_table
    <<~TEXT
      Sandboxes:

      ╭───────────┬────────┬─────────┬───────────╮
      │ Name      │ Branch │ Status  │ Ports     │
      ├───────────┼────────┼─────────┼───────────┤
      │ proj-feat │ feat   │ running │ 3042:3000 │
      │ other-sbx │        │ stopped │           │
      ╰───────────┴────────┴─────────┴───────────╯
    TEXT
  end

  def expected_blank_branch_table
    <<~TEXT
      Sandboxes:

      ╭───────────┬────────┬─────────┬───────╮
      │ Name      │ Branch │ Status  │ Ports │
      ├───────────┼────────┼─────────┼───────┤
      │ proj-feat │        │ running │       │
      ╰───────────┴────────┴─────────┴───────╯
    TEXT
  end

  def expected_json_listing
    payload = {
      "sandboxes" => [
        {
          "name" => "proj-feat",
          "branch" => "feat",
          "status" => "running",
          "ports" => feat_port_mappings
        },
        {
          "name" => "other-sbx",
          "branch" => nil,
          "status" => "stopped"
        }
      ]
    }
    "#{JSON.pretty_generate(payload)}\n"
  end

  describe "#run" do
    it "lists sandboxes with their branch and persisted ports in a table" do
      root = discoverable_project_root
      write_ports_file(
        root,
        "proj-feat",
        feat_port_mappings
      )
      with_fake_cmd do |fake|
        script_sandbox_listing(fake, two_sandbox_listing)
        script_worktree_branches(
          fake,
          root,
          ["feat"]
        )

        expect { Dir.chdir(root) { command.run } }
          .to output(expected_populated_table).to_stdout

        expect(fake.invocations).to eq(
          [
            %w[which sbx],
            %w[sbx ls --json],
            worktree_list_argv(root)
          ]
        )
      end
    end

    it "prints the sandbox list as json in json mode" do
      root = discoverable_project_root
      write_ports_file(
        root,
        "proj-feat",
        feat_port_mappings
      )
      with_fake_cmd do |fake|
        script_sandbox_listing(fake, two_sandbox_listing)
        script_worktree_branches(
          fake,
          root,
          ["feat"]
        )

        expect { Dir.chdir(root) { json_command.run } }
          .to output(expected_json_listing).to_stdout
      end
    end

    it "prints a notice when no sandboxes exist" do
      root = discoverable_project_root
      with_fake_cmd do |fake|
        script_sandbox_listing(fake, [])
        script_worktree_branches(
          fake,
          root,
          []
        )

        expect { Dir.chdir(root) { command.run } }
          .to output("No sandboxes found\n").to_stdout
      end
    end

    it "leaves the branch column blank and still succeeds when branch listing fails" do
      root = discoverable_project_root
      with_fake_cmd do |fake|
        script_sandbox_listing(fake, [two_sandbox_listing.first])
        fake.script_missing(worktree_list_argv(root))

        expect { Dir.chdir(root) { command.run } }
          .to output(expected_blank_branch_table).to_stdout
      end
    end
  end

  describe "#run_inner" do
    it "builds one entry per sandbox with its branch and ports resolved" do
      project = project_with("tmux:\n  session: proj\n")
      write_ports_file(
        project.root,
        "proj-feat",
        feat_port_mappings
      )
      with_fake_cmd do |fake|
        script_sandbox_listing(fake, two_sandbox_listing)
        script_worktree_branches(
          fake,
          project.root,
          ["feat"]
        )

        result = command.run_inner(project)

        owned_entry, unowned_entry = result.sandboxes
        expect(owned_entry).to have_attributes(
          name: "proj-feat",
          branch: "feat",
          status: "running",
          ports: [
            Orn::Sandbox::PortMapping.new(
              host: 3042,
              container: 3000
            )
          ]
        )
        expect(unowned_entry).to have_attributes(
          branch: nil,
          ports: []
        )
      end
    end

    it "skips a branch whose sandbox name cannot be derived" do
      # With session "-", branch "a" derives to the one-character sandbox
      # name "a", which fails validation; the lookup must skip that branch
      # instead of raising, and still match "feature/y" to "feature-y".
      project = project_with(<<~YAML)
        tmux:
          session: "-"
      YAML
      listing = [
        {
          "name" => "feature-y",
          "status" => "running"
        }
      ]
      with_fake_cmd do |fake|
        script_sandbox_listing(fake, listing)
        script_worktree_branches(
          fake,
          project.root,
          ["a", "feature/y"]
        )

        result = command.run_inner(project)

        expect(result.sandboxes.first.branch).to eq("feature/y")
      end
    end
  end

  describe "#find_branch_for_sandbox" do
    def find_branch(project, branches, name)
      list_command = described_class.new(output_mode: Orn::OutputMode.quiet)
      list_command.send(
        :find_branch_for_sandbox,
        project,
        branches,
        name
      )
    end

    it "matches a sandbox back to its branch by name" do
      project = project_with
      branch = "feature/x"
      name = project.sandbox_name(branch)

      expect(
        find_branch(
          project,
          [branch],
          name
        )
      ).to eq(branch)
    end

    it "returns nil when no branch matches" do
      project = project_with

      expect(
        find_branch(
          project,
          ["feature/x"],
          "unrelated-name"
        )
      ).to be_nil
    end

    it "picks the matching branch among several" do
      project = project_with
      name = project.sandbox_name("feature/y")

      expect(
        find_branch(
          project,
          ["feature/x", "feature/y"],
          name
        )
      ).to eq("feature/y")
    end
  end

  describe Orn::Commands::Sbx::List::Entry do
    it "omits ports from JSON when empty" do
      entry = described_class.new(
        name: "sbx-1",
        branch: nil,
        status: "stopped",
        ports: []
      )

      hash = entry.to_json_hash

      aggregate_failures do
        expect(hash).not_to have_key("ports")
        expect(hash["branch"]).to be_nil
      end
    end

    it "includes port mappings in JSON when present" do
      ports = [
        Orn::Sandbox::PortMapping.new(
          host: 3042,
          container: 3000
        ),
        Orn::Sandbox::PortMapping.new(
          host: 6380,
          container: 6379
        )
      ]
      entry = described_class.new(
        name: "sbx-1",
        branch: nil,
        status: "running",
        ports: ports
      )

      hash = entry.to_json_hash

      aggregate_failures do
        expect(hash["ports"][0]["host"]).to eq(3042)
        expect(hash["ports"][1]["container"]).to eq(6379)
      end
    end
  end
end
