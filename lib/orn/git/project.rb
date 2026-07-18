# frozen_string_literal: true

module Orn
  module Git
    # An orn project: the bare-worktree root directory plus its loaded config.
    # Located by following the nearest `.git` pointer file from the current
    # directory.
    class Project
      attr_reader :root, :config

      def initialize(root:, config:)
        @root = root
        @config = config
      end

      # Locates the project root from the current directory and loads its
      # config.
      def self.discover
        root = discover_root
        new(
          root: root,
          config: Orn::Config.load(root)
        )
      end

      # Resolves the project root from the current directory, requiring a
      # `.bare` directory (the orn project marker).
      def self.discover_root
        root = discover_root_from(Dir.pwd)
        return root if File.exist?(File.join(root, ".bare"))

        raise Orn::Error,
          "Not an orn project (no .bare directory found)\n" \
          "Use 'orn clone <url> --base <branch>' to set up a new project"
      end

      # Resolves the project root from `start` by following its nearest `.git`
      # pointer file. Accepts pointers to `.bare` itself (the project root) or
      # to a `.bare/worktrees/<name>` entry (inside a worktree).
      def self.discover_root_from(start)
        git_path = find_git_file(start)
        pointer = read_git_file(git_path).strip

        root = root_from_pointer(git_path, pointer)
        return root if root

        raise Orn::Error,
          "Could not determine orn project root from .git pointer\n" \
          "Use 'orn clone <url> --base <branch>' to set up a new project"
      end

      # The on-disk path for `branch`'s worktree: a direct child of the
      # project root, so slashes in the branch name become subdirectories.
      def worktree_path(branch)
        File.join(@root, branch)
      end

      # Sanitizes the session-and-branch combination into a valid sandbox name
      # and re-validates the result.
      def sandbox_name(branch)
        name = "#{sanitize(Orn::Session.session_name(self))}-#{sanitize(branch)}"
        name = name.gsub(/\A-+|-+\z/, "")
        Orn::Config::Validate.sandbox_name!(name)
        name
      end

      private

      # Keeps [a-zA-Z0-9-], replacing every other character with a hyphen.
      def sanitize(string)
        string.chars.map { |character| character.match?(/[a-zA-Z0-9-]/) ? character : "-" }.join
      end

      # Resolves the project root from a `gitdir: <path>` pointer, or nil when
      # the pointer is not one orn recognizes.
      def self.root_from_pointer(git_path, pointer)
        return nil unless pointer.start_with?("gitdir: ")

        gitdir = pointer.delete_prefix("gitdir: ")
        gitdir = File.join(File.dirname(git_path), gitdir) unless File.absolute_path?(gitdir)
        canonical = resolve_pointer(gitdir)

        # Pointer to `.bare`: the project root is its parent.
        return File.dirname(canonical) if File.basename(canonical) == ".bare"

        # Pointer to `.bare/worktrees/<name>`: walk back up to `.bare`'s parent.
        worktrees = File.dirname(canonical)
        bare = File.dirname(worktrees)
        return File.dirname(bare) if File.basename(worktrees) == "worktrees" && File.basename(bare) == ".bare"

        nil
      end
      private_class_method :root_from_pointer

      def self.resolve_pointer(path)
        File.realpath(path)
      rescue SystemCallError
        raise Orn::Error, "Failed to resolve .git pointer"
      end
      private_class_method :resolve_pointer

      def self.read_git_file(git_path)
        File.read(git_path)
      rescue SystemCallError
        raise Orn::Error, "Failed to read .git file"
      end
      private_class_method :read_git_file

      # Walks up from `start` to the nearest `.git` pointer file. A `.git`
      # directory means a standard repo, not a bare-worktree project, and is
      # rejected.
      def self.find_git_file(start)
        dir = File.expand_path(start)
        loop do
          git_path = File.join(dir, ".git")
          return git_path if File.exist?(git_path) && !File.directory?(git_path)

          if File.directory?(git_path)
            raise Orn::Error,
              "Found a .git directory (not a bare worktree project)\n" \
              "Use 'orn clone <url> --base <branch>' to set up a new project"
          end

          parent = File.dirname(dir)
          raise Orn::Error, "Not inside a git repository" if parent == dir

          dir = parent
        end
      end
      private_class_method :find_git_file
    end
  end
end
