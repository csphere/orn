# frozen_string_literal: true

RSpec.describe Orn::Completions do
  describe ".script" do
    it "generates a bash script that registers a completion and calls orn complete" do
      script = described_class.script("bash")

      aggregate_failures do
        expect(script).to include("complete -F _orn orn")
        expect(script).to include("$(orn complete)")
        expect(script).to include("switch")
      end
    end

    it "generates a zsh script with a compdef header" do
      script = described_class.script("zsh")

      aggregate_failures do
        expect(script).to start_with("#compdef orn")
        expect(script).to include("orn complete")
      end
    end

    it "generates a fish script with per-command completions" do
      script = described_class.script("fish")

      aggregate_failures do
        expect(script).to include("complete -c orn")
        expect(script).to include("(orn complete)")
      end
    end

    it "raises for an unsupported shell" do
      expect { described_class.script("powershell") }.to raise_error(Orn::Error, /Unsupported shell/)
    end
  end
end
