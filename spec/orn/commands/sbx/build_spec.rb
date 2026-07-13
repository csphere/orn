# frozen_string_literal: true

RSpec.describe Orn::Commands::Sbx::Build do
  let(:mode) { Orn::OutputMode.default }

  def project_with(config)
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx-build")), config)
  end

  describe ".run_inner" do
    it "fails without an [sbx] section" do
      project = project_with("git:\n  base: main\n")

      expect { described_class.run_inner(mode, project) }.to raise_error(Orn::Error, /\[sbx\]/)
    end

    it "fails without an [sbx.build] section" do
      project = project_with("sbx:\n  template: img:1\n")

      expect { described_class.run_inner(mode, project) }.to raise_error(Orn::Error, /\[sbx\.build\]/)
    end

    it "fails without a template" do
      project = project_with("sbx:\n  build:\n    dockerfile: Dockerfile\n")

      expect { described_class.run_inner(mode, project) }.to raise_error(Orn::Error, /template/)
    end

    it "fails when the dockerfile is missing" do
      project = project_with("sbx:\n  template: img:1\n  build:\n    dockerfile: nonexistent/Dockerfile\n")

      expect { described_class.run_inner(mode, project) }.to raise_error(Orn::Error, /Dockerfile not found/)
    end
  end
end
