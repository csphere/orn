# frozen_string_literal: true

require "fileutils"

module Orn
  module Commands
    # `orn init`: create a fresh bare-worktree project in the current directory,
    # with no remote involved (the `git init` analogue of `orn clone`).
    class Init
      # Markers whose presence means the directory is already a repo/project.
      EXISTING_PROJECT_MARKERS = {
        ".git" => "Directory already contains a git repository",
        ".bare" => "Directory already contains a .bare repository",
        ".orn" => "Directory already contains an .orn configuration"
      }.freeze

      def initialize(output_mode:)
        @output_mode = output_mode
      end

      def run(base)
        run_in(Dir.pwd, base)
      end

      # Initializes an orn project in `project_dir`: refuses directories that
      # already hold .git, .bare, or .orn, creates the bare repo with an empty
      # initial commit on `base`, then scaffolds config/blackboard/CLAUDE.md and
      # the base worktree. Rolls everything back on failure.
      def run_in(project_dir, base)
        project_name = self.class.derive_project_name(project_dir)
        reject_existing_project!(project_dir)

        @output_mode.status("Initializing orn project: #{project_name}\n")
        build_or_cleanup(project_dir, project_name, base)
        print_next_steps(project_name, base)
        nil
      end

      # The project name is the target directory's basename.
      def self.derive_project_name(project_dir)
        name = File.basename(project_dir)
        raise Orn::Error, "Failed to derive project name from current directory" if name.empty? || name == "/"

        name
      end

      private

      def reject_existing_project!(project_dir)
        EXISTING_PROJECT_MARKERS.each do |marker, message|
          raise Orn::Error, message if File.exist?(File.join(project_dir, marker))
        end
      end

      def build_or_cleanup(project_dir, project_name, base)
        build_project(project_dir, project_name, base)
      rescue StandardError
        cleanup(project_dir, base)
        raise
      end

      def build_project(project_dir, project_name, base)
        cmd = Orn::Cmd.new(output_mode: @output_mode)

        @output_mode.status("  Initializing bare repository")
        cmd.exec("git", "-C", project_dir, "init", "--bare", ".bare")

        @output_mode.status("  Writing .git pointer file")
        Setup.write_git_pointer(project_dir)

        @output_mode.status("  Setting default branch")
        cmd.exec("git", "-C", project_dir, "symbolic-ref", "HEAD", "refs/heads/#{base}")

        @output_mode.status("  Creating initial commit")
        create_empty_commit(cmd, project_dir, base)

        Setup.scaffold_project(@output_mode, project_dir, project_name, base)
      end

      # Creates an initial commit with an empty tree on `base` using plumbing
      # (mktree, commit-tree, update-ref), which works in a bare repo where
      # `git commit` has no index or working tree. mktree reads its (empty)
      # stdin, which Open3 closes for us.
      def create_empty_commit(cmd, project_dir, base)
        tree_hash = cmd.run("git", "-C", project_dir, "mktree").stdout.strip
        commit = cmd.run("git", "-C", project_dir, "commit-tree", tree_hash, "-m", "Initial commit")
        cmd.exec("git", "-C", project_dir, "update-ref", "refs/heads/#{base}", commit.stdout.strip)
      end

      def cleanup(project_dir, base)
        FileUtils.rm_rf(File.join(project_dir, ".bare"))
        FileUtils.rm_f(File.join(project_dir, ".git"))
        FileUtils.rm_rf(File.join(project_dir, ".orn"))
        FileUtils.rm_f(File.join(project_dir, "CLAUDE.md"))
        FileUtils.rm_rf(File.join(project_dir, base))
      end

      def print_next_steps(project_name, base)
        @output_mode.status("\nDone. Project initialized at ./")
        @output_mode.status("Base worktree: #{project_name}/#{base}/")
        @output_mode.status("\nNext steps:")
        @output_mode.status("  cd #{base}")
        @output_mode.status("  orn switch feature/your-branch")
      end
    end
  end
end
