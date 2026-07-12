# frozen_string_literal: true

RSpec.describe Orn::CLI do
  describe "version" do
    it "prints the orn version" do
      expect { described_class.start(["version"]) }
        .to output("orn #{Orn::VERSION}\n").to_stdout
    end

    it "is reachable through the --version flag" do
      expect { described_class.start(["--version"]) }
        .to output("orn #{Orn::VERSION}\n").to_stdout
    end
  end
end
