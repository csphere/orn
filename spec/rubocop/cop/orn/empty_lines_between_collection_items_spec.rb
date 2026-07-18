# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../.rubocop/cop/orn/empty_lines_between_collection_items"

RSpec.describe RuboCop::Cop::Orn::EmptyLinesBetweenCollectionItems, :config do
  include RuboCop::RSpec::ExpectOffense

  it "flags a blank line between keyword arguments" do
    expect_offense(<<~RUBY)
      Worktree.new(
        root: root,

        output_mode: quiet
        ^^^^^^^^^^^^^^^^^^ Do not leave blank lines between collection items.
      )
    RUBY

    expect_correction(<<~RUBY)
      Worktree.new(
        root: root,
        output_mode: quiet
      )
    RUBY
  end

  it "flags a blank line between hash literal pairs" do
    expect_offense(<<~RUBY)
      config = {
        name: "orn",

        base: "main"
        ^^^^^^^^^^^^ Do not leave blank lines between collection items.
      }
    RUBY

    expect_correction(<<~RUBY)
      config = {
        name: "orn",
        base: "main"
      }
    RUBY
  end

  it "flags a blank line between array items" do
    expect_offense(<<~RUBY)
      items = [
        "one",

        "two"
        ^^^^^ Do not leave blank lines between collection items.
      ]
    RUBY

    expect_correction(<<~RUBY)
      items = [
        "one",
        "two"
      ]
    RUBY
  end

  it "accepts a comment line between items" do
    expect_no_offenses(<<~RUBY)
      config = {
        name: "orn",
        # the branch worktrees are created from
        base: "main"
      }
    RUBY
  end

  it "accepts a blank line inside a heredoc item" do
    expect_no_offenses(<<~RUBY)
      messages = [
        <<~FIRST,
          one

          two
        FIRST
        "three"
      ]
    RUBY
  end

  it "accepts adjacent items with no blank lines" do
    expect_no_offenses(<<~RUBY)
      Worktree.new(
        root: root,
        output_mode: quiet
      )
    RUBY
  end
end
