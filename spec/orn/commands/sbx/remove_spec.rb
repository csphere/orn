# frozen_string_literal: true

RSpec.describe Orn::Commands::Sbx::Remove do
  # `run_inner` requires the sbx CLI on PATH, so its own round-trip is a system
  # concern. The port-state cleanup it delegates to the sandbox module is
  # verifiable without sbx present.
  describe "port-state cleanup" do
    it "deletes the persisted ports file for a branch's sandbox" do
      root = register_temp_dir(Dir.mktmpdir("orn-sbx-remove"))
      project = make_project(root, "git:\n  base: main\n")
      orn_dir = File.join(root, ".orn")
      name = project.sandbox_name("feature/x")
      Orn::Sandbox::Ports.persist_ports(
        orn_dir,
        name,
        [
          Orn::Sandbox::PortMapping.new(
            host: 3042,
            container: 3000
          )
        ]
      )
      expect(File).to exist(
        File.join(
          orn_dir,
          "sandbox",
          "#{name}.ports"
        )
      )

      Orn::Sandbox::Ports.remove_ports_file(orn_dir, name)

      expect(File).not_to exist(
        File.join(
          orn_dir,
          "sandbox",
          "#{name}.ports"
        )
      )
    end
  end
end
