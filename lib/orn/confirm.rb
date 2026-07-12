# frozen_string_literal: true

require "pathname"

module Orn
  # Interactive yes/no confirmation prompts, written to a writer and read from a
  # reader (real stdin/stderr in production, StringIO in tests).
  module Confirm
    # Prompts before deleting the local and remote branches for `branch`;
    # raises "Aborted" if declined. Returns immediately (nil) when neither
    # branch exists.
    def self.prune_interactive(root, branch)
      worktree = Orn::Git::Worktree.new(root: root, output_mode: Orn::OutputMode.default)
      has_local = worktree.local_branch_exists?(branch)
      has_remote = worktree.remote_branch_exists?("origin", branch)
      return if !has_local && !has_remote

      confirmed = with_stdin_stderr { |reader, writer| prune(branch, has_local, has_remote, reader, writer) }
      raise Orn::Error, "Aborted" unless confirmed

      nil
    end

    # Writes the prune summary and reads a yes/no answer.
    def self.prune(branch, has_local, has_remote, reader, writer)
      writer.puts "Remove worktree and delete branches for '#{branch}'?"
      writer.puts "This will delete:"
      writer.puts "  - Local branch: #{branch}" if has_local
      writer.puts "  - Remote branch: origin/#{branch}" if has_remote
      writer.print "Continue? [y/N] "
      writer.flush
      read_yes_no(reader)
    end

    # Asks whether to create the missing global config at `config_path`, shown
    # with $HOME abbreviated to ~.
    def self.global_config(config_path, reader, writer)
      writer.puts
      writer.puts "  Global config not found: #{display_path(config_path)}"
      writer.print "  Create it? [y/N] "
      writer.flush
      read_yes_no(reader)
    end

    # Warns that symlink destinations are missing from .gitignore and asks
    # whether to add them (and stage the change) or cancel.
    def self.gitignore(paths, reader, writer)
      writer.puts
      paths.each { |path| writer.puts "warning: symlink destination '#{path}' is not in .gitignore" }
      writer.puts
      writer.puts "  y: add to .gitignore and stage the change"
      writer.puts "  n: cancel and remove the worktree"
      writer.print "\nProceed? [y/n] "
      writer.flush
      read_yes_no(reader)
    end

    # Reads a line and reports whether it is "y"/"yes" (case-insensitive).
    # EOF (nil) and blank lines count as no.
    def self.read_yes_no(reader)
      input = reader.gets.to_s
      %w[y yes].include?(input.strip.downcase)
    end

    def self.with_stdin_stderr(&block)
      block.call($stdin, $stderr)
    end

    # Abbreviates paths under $HOME to ~/... for display.
    def self.display_path(path)
      home = Orn::Fs.home_dir
      return path if home.nil?

      path_parts = Pathname.new(path).each_filename.to_a
      home_parts = Pathname.new(home).each_filename.to_a
      return path unless path_parts[0, home_parts.length] == home_parts

      File.join("~", *path_parts[home_parts.length..])
    end

    private_class_method :read_yes_no, :with_stdin_stderr, :display_path
  end
end
