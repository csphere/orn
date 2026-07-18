# frozen_string_literal: true

RSpec.describe Orn::Commands::Output do
  describe ".worktree_table" do
    context "with no rows" do
      it "prints a not-found notice" do
        expect { described_class.worktree_table("repo", ["Branch"], []) }
          .to output("No worktrees found\n").to_stdout
      end
    end

    context "with rows" do
      it "prints a bordered table headed by the repo" do
        expect { described_class.worktree_table("myrepo", ["Branch"], [["main"], ["feature/x"]]) }
          .to output(%r{Worktrees in myrepo.*Branch.*main.*feature/x}m).to_stdout
      end
    end
  end

  describe ".print_json" do
    it "prints pretty-formatted JSON" do
      expect do
        described_class.print_json(
          "repo" => "x",
          "worktrees" => []
        )
      end
        .to output(/\{\n  "repo": "x",\n  "worktrees": \[\]\n\}/).to_stdout
    end
  end
end
