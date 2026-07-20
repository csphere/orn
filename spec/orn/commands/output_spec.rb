# frozen_string_literal: true

RSpec.describe Orn::Commands::Output do
  describe ".worktree_table" do
    context "with no rows" do
      it "prints a not-found notice" do
        expect do
          described_class.worktree_table(
            "repo",
            ["Branch"],
            []
          )
        end
          .to output("No worktrees found\n").to_stdout
      end
    end

    context "with rows" do
      it "prints a bordered table headed by the repo" do
        expect do
          described_class.worktree_table(
            "myrepo",
            ["Branch"],
            [["main"], ["feature/x"]]
          )
        end
          .to output(%r{Worktrees in myrepo.*Branch.*main.*feature/x}m).to_stdout
      end
    end
  end

  describe ".run_multi_branch" do
    it "skips the per-result printer in json mode" do
      printed_results = []
      printer = ->(result) { printed_results << result }

      results, errors = described_class.run_multi_branch(
        Orn::OutputMode.quiet,
        ["main", "feature/x"],
        printer
      ) { |branch| "removed #{branch}" }

      aggregate_failures do
        expect(printed_results).to be_empty
        expect(results).to eq(["removed main", "removed feature/x"])
        expect(errors).to be_empty
      end
    end
  end

  describe ".finish_multi_branch" do
    it "raises with the failure count when any branch errored" do
      expect do
        described_class.finish_multi_branch(
          Orn::OutputMode.default,
          [],
          ["a: boom", "b: boom"],
          3,
          action: "remove"
        )
      end
        .to raise_error(Orn::Error, "failed to remove 2 of 3 worktrees")
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
