# frozen_string_literal: true

module Orn
  # Filesystem utilities: empty-directory pruning and home/XDG directory
  # resolution.
  module Fs
    # Removes direct children of `root` whose subtrees contain no files,
    # skipping dot-directories (.bare, .orn, ...). Cleans up branch-prefix
    # directories (e.g. feature/) left behind after worktree removal.
    def self.prune_empty_dirs(root)
      Dir.children(root).each do |name|
        next if name.start_with?(".")

        path = File.join(root, name)
        next unless File.directory?(path)

        remove_empty_dir(path) if prune_subtree(path)
      end
      nil
    end

    # The user's home directory from $HOME, or nil when unset. Strictly
    # $HOME: Dir.home would fall back to the passwd database, which we do not
    # want.
    def self.home_dir
      ENV.fetch("HOME", nil) # rubocop:disable Style/EnvHome
    end

    # An XDG base directory: $<var> when set and non-empty, otherwise
    # $HOME/<home_fallback>. Returns nil when neither is available.
    def self.xdg_dir(var, home_fallback)
      value = ENV.fetch(var, nil)
      return value if value && !value.empty?

      home = home_dir
      return nil if home.nil?

      File.join(home, home_fallback)
    end

    # Recursively removes empty subdirectories of `dir`; returns whether
    # `dir` itself is empty afterwards (so the caller may remove it).
    def self.prune_subtree(dir)
      return false unless File.directory?(dir)

      empty = true
      Dir.children(dir).each do |name|
        path = File.join(dir, name)
        unless File.directory?(path)
          empty = false
          next
        end

        if prune_subtree(path)
          remove_empty_dir(path)
        else
          empty = false
        end
      end
      empty
    end
    private_class_method :prune_subtree

    def self.remove_empty_dir(path)
      Dir.rmdir(path)
    rescue SystemCallError
      nil
    end
    private_class_method :remove_empty_dir
  end
end
