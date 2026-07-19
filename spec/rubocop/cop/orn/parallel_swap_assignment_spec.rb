# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../.rubocop/cop/orn/parallel_swap_assignment"

RSpec.describe RuboCop::Cop::Orn::ParallelSwapAssignment, :config do
  include RuboCop::RSpec::ExpectOffense

  it "flags a variable swap" do
    expect_offense(<<~RUBY)
      first, second = second, first
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Use separate assignments with a temporary variable instead of a parallel swap.
    RUBY
  end

  it "flags an element swap" do
    expect_offense(<<~RUBY)
      windows[i], windows[j] = windows[j], windows[i]
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Use separate assignments with a temporary variable instead of a parallel swap.
    RUBY
  end

  it "flags a swap where a value is wrapped in an expression" do
    expect_offense(<<~RUBY)
      low, high = high, low + 1
      ^^^^^^^^^^^^^^^^^^^^^^^^^ Use separate assignments with a temporary variable instead of a parallel swap.
    RUBY
  end

  it "accepts destructuring a method return" do
    expect_no_offenses(<<~RUBY)
      first, rest = entries
    RUBY
  end

  it "accepts sequential assignment through a temporary" do
    expect_no_offenses(<<~RUBY)
      displaced_window = windows[i]
      windows[i] = windows[j]
      windows[j] = displaced_window
    RUBY
  end

  it "leaves independent parallel assignment to the stock cop" do
    expect_no_offenses(<<~RUBY)
      width, height = 80, 24
    RUBY
  end
end
