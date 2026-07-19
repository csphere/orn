# frozen_string_literal: true

RSpec.describe Orn::OutputMode do
  describe ".default" do
    it "is neither verbose nor json" do
      mode = described_class.default

      expect(mode.verbose).to be(false)
      expect(mode.json).to be(false)
    end
  end

  describe ".quiet" do
    it "suppresses human output by enabling json" do
      mode = described_class.quiet

      expect(mode.json).to be(true)
      expect(mode.verbose).to be(false)
    end
  end

  describe ".from_options" do
    it "enables verbose when the options hash asks for it" do
      mode = described_class.from_options({ verbose: true })

      expect(mode.verbose).to be(true)
      expect(mode.json).to be(false)
    end

    it "enables json when the options hash asks for it" do
      mode = described_class.from_options({ json: true })

      expect(mode.json).to be(true)
      expect(mode.verbose).to be(false)
    end

    it "enables both flags together" do
      mode = described_class.from_options(
        {
          verbose: true,
          json: true
        }
      )

      expect(mode.verbose).to be(true)
      expect(mode.json).to be(true)
    end
  end

  describe "#status" do
    context "when json is enabled" do
      it "writes nothing to stderr" do
        expect { described_class.quiet.status("hidden") }.not_to output.to_stderr
      end
    end

    context "when json is disabled" do
      it "writes the message to stderr" do
        expect { described_class.default.status("shown") }.to output("shown\n").to_stderr
      end
    end
  end
end
