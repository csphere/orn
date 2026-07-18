# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../.rubocop/cop/orn/multi_argument_line_breaks"

RSpec.describe RuboCop::Cop::Orn::MultiArgumentLineBreaks, :config do
  include RuboCop::RSpec::ExpectOffense

  let(:cop_config) do
    {
      "MaxArgsOnOneLine" => 2,
      "AllowedMethods" => ["tmux_exec"]
    }
  end

  it "flags a single-line call with three arguments" do
    expect_offense(<<~RUBY)
      Check.warning("github-secret", false, missing)
                                     ^^^^^ Write each argument on its own line when a call has more than 2 arguments.
                                            ^^^^^^^ Write each argument on its own line when a call has more than 2 arguments.
    RUBY

    expect_correction(<<~RUBY)
      Check.warning("github-secret",
      false,
      missing)
    RUBY
  end

  it "accepts a two-argument call on one line" do
    expect_no_offenses(<<~RUBY)
      File.join(root, ".bare")
    RUBY
  end

  it "accepts an allowed method at any argument count" do
    expect_no_offenses(<<~RUBY)
      tmux_exec(output_mode, "set-option", "-p", "-u", "-t", pane, name)
    RUBY
  end

  it "accepts a call already broken one argument per line" do
    expect_no_offenses(<<~RUBY)
      Data.define(
        :output_mode,
        :project,
        :branch
      )
    RUBY
  end
end
