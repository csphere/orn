# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../.rubocop/cop/orn/multi_pair_hash_line_breaks"

RSpec.describe RuboCop::Cop::Orn::MultiPairHashLineBreaks, :config do
  include RuboCop::RSpec::ExpectOffense

  it "flags a single-line hash literal with two pairs" do
    expect_offense(<<~RUBY)
      config = { name: "orn", base: "main" }
                              ^^^^^^^^^^^^ Write each pair of a multi-pair hash on its own line.
    RUBY

    expect_correction(<<~RUBY)
      config = { name: "orn",
      base: "main" }
    RUBY
  end

  it "flags single-line keyword arguments with two pairs" do
    expect_offense(<<~RUBY)
      Worktree.new(root: root, output_mode: quiet)
                               ^^^^^^^^^^^^^^^^^^ Write each pair of a multi-pair hash on its own line.
    RUBY

    expect_correction(<<~RUBY)
      Worktree.new(root: root,
      output_mode: quiet)
    RUBY
  end

  it "accepts a single-pair hash on one line" do
    expect_no_offenses(<<~RUBY)
      config = { name: "orn" }
    RUBY
  end

  it "accepts a multi-pair hash already broken one pair per line" do
    expect_no_offenses(<<~RUBY)
      Worktree.new(
        root: root,
        output_mode: quiet
      )
    RUBY
  end
end
