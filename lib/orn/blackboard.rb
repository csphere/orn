# frozen_string_literal: true

require "pathname"
require "fileutils"

module Orn
  # Agent coordination via the blackboard protocol: per-branch markdown files
  # under .orn/blackboard that agents read and write to share status across
  # worktrees.
  module Blackboard
    # Creates .orn/blackboard seeded with the bundled PROTOCOL.md and
    # TEMPLATE.md. A no-op if the directory already exists, so user edits to
    # either file are preserved.
    def self.ensure_dir(root)
      dir = blackboard_dir(root)
      return if File.exist?(dir)

      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "PROTOCOL.md"), protocol)
      File.write(File.join(dir, "TEMPLATE.md"), template)
      nil
    end

    # Writes a fresh blackboard.md for `branch` from the template and returns
    # its path. Overwrites any existing entry.
    def self.create_entry(root, branch)
      entry_dir = File.join(blackboard_dir(root), branch)
      FileUtils.mkdir_p(entry_dir)
      entry_path = File.join(entry_dir, "blackboard.md")
      File.write(entry_path, render_template(branch))
      entry_path
    end

    # Deletes the blackboard entry for `branch` and prunes now-empty parent
    # directories up to, but not including, the blackboard root. Best-effort:
    # all filesystem errors are ignored.
    def self.remove_entry(root, branch)
      blackboard_root = blackboard_dir(root)
      entry_dir = File.join(blackboard_root, branch)
      FileUtils.rm_rf(entry_dir)
      prune_empty_parents(entry_dir, blackboard_root)
      nil
    end

    def self.render_template(branch)
      template.gsub("<branch>", branch)
    end

    def self.blackboard_dir(root)
      File.join(root, ".orn/blackboard")
    end

    def self.protocol
      Orn::Template.new("blackboard/PROTOCOL.md").read
    end

    def self.template
      Orn::Template.new("blackboard/TEMPLATE.md").read
    end

    def self.prune_empty_parents(start_dir, blackboard_root)
      current = start_dir
      loop do
        parent = File.dirname(current)
        break if parent == blackboard_root || !under_directory?(parent, blackboard_root)
        break unless try_remove_dir(parent)

        current = parent
      end
    end

    def self.under_directory?(path, ancestor)
      path_parts = Pathname.new(path).each_filename.to_a
      ancestor_parts = Pathname.new(ancestor).each_filename.to_a
      path_parts[0, ancestor_parts.length] == ancestor_parts
    end

    def self.try_remove_dir(dir)
      Dir.rmdir(dir)
      true
    rescue SystemCallError
      false
    end

    private_class_method :blackboard_dir, :protocol, :template, :prune_empty_parents,
      :under_directory?, :try_remove_dir
  end
end
