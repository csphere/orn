# frozen_string_literal: true

RSpec.describe Orn::Template do
  describe "#read" do
    context "when the template exists" do
      it "returns the file contents" do
        content = described_class.new("CLAUDE.md").read

        expect(content).to include("Bare worktree workspace")
      end
    end

    context "when the template is missing" do
      it "raises an error naming the template" do
        expect { described_class.new("does-not-exist.md").read }
          .to raise_error(Orn::Error, /does-not-exist\.md/)
      end
    end
  end
end
