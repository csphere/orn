# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]

desc "Regenerate docs/cli.md from the CLI definitions"
task :docs do
  require "orn"
  require "orn/docs/cli_reference"
  FileUtils.mkdir_p("docs")
  File.write("docs/cli.md", Orn::Docs::CliReference.generate)
  puts "wrote docs/cli.md"
end
