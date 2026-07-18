# frozen_string_literal: true

require_relative "lib/orn/version"

Gem::Specification.new do |spec|
  spec.name = "orn"
  spec.version = Orn::VERSION
  spec.authors = ["Sean Kennedy"]
  spec.email = ["sean.kennedy@seaseducation.com"]

  spec.summary = "Git worktree and tmux workspace manager."
  spec.description = "orn manages git bare-worktree projects and their tmux " \
                     "windows, sandboxes, and agent coordination."
  spec.homepage = "https://github.com/seaseducation/orn"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(
    %w[git ls-files -z],
    chdir: __dir__,
    err: IO::NULL
  ) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .rspec spec/ .github/ .rubocop.yml .rubocop/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"
end
