# frozen_string_literal: true

RSpec.describe Orn::Commands::Sbx::List do
  def project_with(config = "git:\n  base: main\n")
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx-list")), config)
  end

  def find_branch(project, branches, name)
    command = described_class.new(output_mode: Orn::OutputMode.quiet)
    command.send(:find_branch_for_sandbox, project, branches, name)
  end

  describe "#find_branch_for_sandbox" do
    it "matches a sandbox back to its branch by name" do
      project = project_with
      branch = "feature/x"
      name = project.sandbox_name(branch)

      expect(find_branch(project, [branch], name)).to eq(branch)
    end

    it "returns nil when no branch matches" do
      project = project_with

      expect(find_branch(project, ["feature/x"], "unrelated-name")).to be_nil
    end

    it "picks the matching branch among several" do
      project = project_with
      name = project.sandbox_name("feature/y")

      expect(find_branch(project, ["feature/x", "feature/y"], name)).to eq("feature/y")
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
