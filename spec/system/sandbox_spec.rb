# frozen_string_literal: true

require "open3"

# Live sandbox flows against real docker and sbx: the sbx new/remove
# lifecycle, setup-command execution behind the trust prompt, and the
# `switch --sbx` orchestration that provisions worktree, tmux window, and
# sandbox together. Gated by `:sbx_system` (Docker auth) on top of `:system`.
RSpec.describe "orn sandbox flows", :sbx_system, :system do
  include_context "with a sandbox system project"

  describe "sandbox lifecycle" do
    let(:branch) { "feature/sandbox-lifecycle" }

    it "creates a sandbox for an existing worktree and removes it" do
      project = clone_project(make_remote, <<~YAML)
        orn_version: "#{Orn::VERSION}"
        git:
          base: main
        tmux:
          session: "#{session}"
        sbx:
          agent_type: shell
      YAML
      orn_ok("wt", "new", branch, chdir: project)

      created = orn_json("sbx", "new", branch, chdir: project)
      expect(created).to include(
        "name" => sandbox_name,
        "branch" => branch
      )
      expect(listed_sandbox_names(project)).to include(sandbox_name)

      removal = orn_ok("sbx", "remove", branch, chdir: project)
      expect(removal).to include("Removed sandbox")
      expect(listed_sandbox_names(project)).not_to include(sandbox_name)
    end
  end

  describe "setup commands" do
    let(:branch) { "feature/sandbox-setup" }

    it "runs the approved setup commands inside the sandbox" do
      project = clone_project(make_remote, <<~YAML)
        orn_version: "#{Orn::VERSION}"
        git:
          base: main
        tmux:
          session: "#{session}"
        sbx:
          agent_type: shell
          setup: touch /tmp/orn-setup-marker
      YAML
      orn_ok("wt", "new", branch, chdir: project)

      # Setup commands are gated on trust approval, so the first run goes
      # through a pseudo-terminal to answer the prompt.
      output, status = orn_pty(
        "sbx",
        "new",
        branch,
        chdir: project,
        input: "y\n"
      )
      expect(status).to be_success, "orn sbx new failed:\n#{output}"
      expect(output).to include("Approve?")

      expect(setup_marker_exists?).to be(true), "setup command should have created the marker file"
    end

    def setup_marker_exists?
      _stdout, _stderr, status = Open3.capture3(
        "sbx",
        "exec",
        sandbox_name,
        "--",
        "test",
        "-f",
        "/tmp/orn-setup-marker"
      )
      status.success?
    end
  end

  describe "switch --sbx orchestration" do
    let(:branch) { "feature/full-provision" }

    it "provisions worktree, window, and sandbox together and removes them together" do
      project = clone_project(make_remote, <<~YAML)
        orn_version: "#{Orn::VERSION}"
        git:
          base: main
        tmux:
          session: "#{session}"
        sbx:
          agent_type: shell
      YAML

      result = orn_json("switch", "--sbx", branch, chdir: project)
      expect(result).to include(
        "branch" => branch,
        "action" => "created",
        "sandbox_name" => sandbox_name
      )
      expect_provisioned(project)

      orn_ok("remove", branch, chdir: project)
      expect_torn_down(project)
    end

    def expect_provisioned(project)
      aggregate_failures do
        expect(File).to exist(File.join(project, branch))
        expect(tmux_window_names(session)).to include(branch)
        expect(listed_sandbox_names(project)).to include(sandbox_name)
      end
    end

    def expect_torn_down(project)
      aggregate_failures do
        expect(File).not_to exist(File.join(project, branch))
        expect(tmux_window_names(session)).not_to include(branch)
        expect(listed_sandbox_names(project)).not_to include(sandbox_name)
      end
    end
  end
end
