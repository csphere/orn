# frozen_string_literal: true

RSpec.describe Orn::Tmux::Layout do
  def col(*panes)
    Orn::Config::Column.new(panes: panes)
  end

  def row_panes(*panes)
    Orn::Config::Row.new(panes: panes, columns: [])
  end

  def row_cols(*columns)
    Orn::Config::Row.new(panes: [], columns: columns)
  end

  def split(direction, target, percentage, result)
    described_class::Split.new(direction: direction, target: target, percentage: percentage, result: result)
  end

  def pane_command(pane, command)
    described_class::PaneCommand.new(pane: pane, command: command)
  end

  describe ".split_percentage" do
    it "splits so panes end up equal after subsequent splits" do
      expect([1, 2, 3, 4].map { |remaining| described_class.split_percentage(remaining) }).to eq([50, 67, 75, 80])
    end
  end

  describe ".plan_columns" do
    it "is empty for no columns" do
      plan = described_class.plan_columns([])

      expect(plan.splits).to be_empty
      expect(plan.commands).to be_empty
      expect(plan.focus_pane).to eq(0)
    end

    it "queues the command with no splits for a single pane" do
      plan = described_class.plan_columns([col("vim")])

      expect(plan.splits).to be_empty
      expect(plan.commands).to eq([pane_command(0, "vim")])
    end

    it "stacks three panes vertically in one column", :aggregate_failures do
      plan = described_class.plan_columns([col("a", "b", "c")])

      expect(plan.splits).to eq([
        split(:vertical, 0, 67, 1),
        split(:vertical, 1, 50, 2)
      ])
      expect(plan.commands).to eq([pane_command(0, "a"), pane_command(1, "b"), pane_command(2, "c")])
      expect(plan.focus_pane).to eq(0)
    end

    it "splits two columns of two panes each", :aggregate_failures do
      plan = described_class.plan_columns([col("a", "b"), col("c", "d")])

      expect(plan.splits).to eq([
        split(:horizontal, 0, 50, 1),
        split(:vertical, 0, 50, 2),
        split(:vertical, 1, 50, 3)
      ])
      expect(plan.commands).to eq([
        pane_command(0, "a"), pane_command(2, "b"),
        pane_command(1, "c"), pane_command(3, "d")
      ])
    end

    it "handles three columns with varying pane counts", :aggregate_failures do
      plan = described_class.plan_columns([col("a"), col("b", "c"), col("d", "e", "f")])

      expect(plan.splits).to eq([
        split(:horizontal, 0, 67, 1),
        split(:horizontal, 1, 50, 2),
        split(:vertical, 1, 50, 3),
        split(:vertical, 2, 67, 4),
        split(:vertical, 4, 50, 5)
      ])
      expect(plan.commands.map(&:pane)).to eq([0, 1, 3, 2, 4, 5])
    end

    it "creates panes but no commands for bare terminals" do
      plan = described_class.plan_columns([col(""), col("")])

      expect(plan.splits).to eq([split(:horizontal, 0, 50, 1)])
      expect(plan.commands).to be_empty
    end

    it "queues only non-empty commands" do
      plan = described_class.plan_columns([col("vim", ""), col("", "cargo test")])

      expect(plan.commands).to eq([pane_command(0, "vim"), pane_command(3, "cargo test")])
    end
  end

  describe ".plan_rows" do
    it "is empty for no rows" do
      plan = described_class.plan_rows([])

      expect(plan.splits).to be_empty
      expect(plan.focus_pane).to eq(0)
    end

    it "splits two rows of panes vertically", :aggregate_failures do
      plan = described_class.plan_rows([row_panes("top"), row_panes("bottom")])

      expect(plan.splits).to eq([split(:vertical, 0, 50, 1)])
      expect(plan.commands).to eq([pane_command(0, "top"), pane_command(1, "bottom")])
    end

    it "splits a row with nested columns", :aggregate_failures do
      plan = described_class.plan_rows([
        row_panes("main-command"),
        row_cols(col("cmd1", "cmd2"), col("cmd3", "cmd4"))
      ])

      expect(plan.splits).to eq([
        split(:vertical, 0, 50, 1),
        split(:horizontal, 1, 50, 2),
        split(:vertical, 1, 50, 3),
        split(:vertical, 2, 50, 4)
      ])
      expect(plan.commands).to eq([
        pane_command(0, "main-command"),
        pane_command(1, "cmd1"), pane_command(3, "cmd2"),
        pane_command(2, "cmd3"), pane_command(4, "cmd4")
      ])
    end

    it "handles three rows, one with nested columns", :aggregate_failures do
      plan = described_class.plan_rows([
        row_panes("top"),
        row_cols(col("left"), col("right")),
        row_panes("bottom")
      ])

      expect(plan.splits).to eq([
        split(:vertical, 0, 67, 1),
        split(:vertical, 1, 50, 2),
        split(:horizontal, 1, 50, 3)
      ])
      expect(plan.commands.map(&:pane)).to eq([0, 1, 3, 2])
    end

    it "stacks multiple panes in a single row" do
      plan = described_class.plan_rows([row_panes("a", "b", "c")])

      expect(plan.splits).to eq([split(:vertical, 0, 67, 1), split(:vertical, 1, 50, 2)])
      expect(plan.commands.map(&:pane)).to eq([0, 1, 2])
    end

    it "focuses the first pane" do
      plan = described_class.plan_rows([row_panes("a"), row_cols(col("b"), col("c"))])

      expect(plan.focus_pane).to eq(0)
    end
  end

  describe ".substitute_template_vars" do
    it "replaces known placeholders, leaving unknown ones and plain text alone" do
      vars = { "sandbox" => "my-sbx", "branch" => "feature/x" }

      expect(described_class.substitute_template_vars("echo {{branch}} in {{sandbox}}", vars))
        .to eq("echo feature/x in my-sbx")
      expect(described_class.substitute_template_vars("run {{unknown}}", vars)).to eq("run {{unknown}}")
      expect(described_class.substitute_template_vars("cargo test", vars)).to eq("cargo test")
    end

    it "replaces every occurrence of a placeholder" do
      vars = { "sandbox" => "my-sbx" }

      expect(described_class.substitute_template_vars("{{sandbox}} && echo {{sandbox}}", vars))
        .to eq("my-sbx && echo my-sbx")
    end
  end
end
