# frozen_string_literal: true

require "pathname"

module Orn
  # Filesystem utilities: empty-directory pruning and home/XDG directory
  # resolution.
  module Fs
    # Whether `path` is `ancestor` or a path inside it, comparing whole
    # components so a sibling like "orn-other" does not match "orn".
    def self.within?(path, ancestor)
      path_parts = Pathname.new(path).each_filename.to_a
      ancestor_parts = Pathname.new(ancestor).each_filename.to_a
      path_parts[0, ancestor_parts.length] == ancestor_parts
    end

    # Removes the branch's now-empty prefix directories (feature/ for
    # feature/x) left behind after worktree removal, deepest first. rmdir
    # only ever deletes empty directories, so prefixes shared with other
    # worktrees survive, and nothing outside the branch's own path is
    # visited: no recursion, no symlink following.
    def self.prune_branch_dirs(root, branch)
      prefixes = branch.split("/")[0...-1]
      until prefixes.empty?
        remove_empty_dir(File.join(root, *prefixes))
        prefixes.pop
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

    def self.remove_empty_dir(path)
      Dir.rmdir(path)
    rescue SystemCallError
      nil
    end
    private_class_method :remove_empty_dir
  end
end
