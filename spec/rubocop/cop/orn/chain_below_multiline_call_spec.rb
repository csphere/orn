# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../.rubocop/cop/orn/chain_below_multiline_call"

RSpec.describe RuboCop::Cop::Orn::ChainBelowMultilineCall, :config do
  include RuboCop::RSpec::ExpectOffense

  it "flags a chained call on its own line below a multiline call" do
    expect_offense(<<~RUBY)
      Worktree.new(
        root: root,
        output_mode: output_mode
      )
        .remove(path)
        ^^^^^^^ Assign the multiline receiver to a named variable instead of chaining below it.
    RUBY
  end

  it "flags a chained call below a multiline array literal" do
    expect_offense(<<~RUBY)
      [
        first,
        second,
        third
      ]
        .compact
        ^^^^^^^^ Assign the multiline receiver to a named variable instead of chaining below it.
    RUBY
  end

  it "accepts chaining on the closing delimiter line" do
    expect_no_offenses(<<~RUBY)
      Worktree.new(
        root: root,
        output_mode: output_mode
      ).branches
    RUBY
  end

  it "accepts a fluent chain off a single-line receiver" do
    expect_no_offenses(<<~RUBY)
      entries
        .select { |entry| entry.branch }
        .map { |entry| entry.path }
    RUBY
  end

  it "accepts calling through a named variable" do
    expect_no_offenses(<<~RUBY)
      worktree = Worktree.new(
        root: root,
        output_mode: output_mode
      )
      worktree.remove(path)
    RUBY
  end
end
