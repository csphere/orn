# frozen_string_literal: true

RSpec.describe Orn::Commands::Sbx::Doctor do
  let(:mode) { Orn::OutputMode.default }

  def project_with(config)
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx-doctor")), config)
  end

  describe ".run_inner" do
    it "fails without an [sbx] section" do
      project = project_with("git:\n  base: main\n")

      expect { described_class.run_inner(mode, project) }.to raise_error(Orn::Error, /No sbx section/)
    end

    it "returns the standard checks for a minimal config" do
      project = project_with("sbx:\n  template: img:1\n")

      names = described_class.run_inner(mode, project).checks.map(&:name)

      aggregate_failures do
        expect(names).to include("sbx", "docker", "template")
        if Orn::Sandbox.send(:macos?)
          expect(names).to include("colima")
        else
          expect(names).not_to include("colima")
        end
      end
    end

    it "adds an env check per build arg" do
      project = project_with("sbx:\n  template: img:1\n  build:\n    build_args: [MY_BUILD_ARG]\n")

      names = described_class.run_inner(mode, project).checks.map(&:name)

      expect(names).to include("env:MY_BUILD_ARG")
    end

    it "reports all_passed as the conjunction of every check" do
      project = project_with("sbx:\n  template: img:1\n")

      result = described_class.run_inner(mode, project)

      expect(result.all_passed).to eq(result.checks.all?(&:passed))
    end
  end
end
