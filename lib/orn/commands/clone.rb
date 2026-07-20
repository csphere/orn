# frozen_string_literal: true

require "fileutils"

module Orn
  module Commands
    # `orn clone`: clone a remote repository into a new bare-worktree project.
    class Clone
      def initialize(output_mode:)
        @output_mode = output_mode
      end

      # Creates ./<name>/ (name derived from the URL) and clones into it,
      # deleting the directory again if any step fails.
      def run(url, base)
        # git parses options anywhere on the line, so a flag-shaped URL
        # would change what git clone does instead of being cloned.
        raise Orn::Error, "Invalid repository URL '#{url}': cannot start with '-'" if url.start_with?("-")

        project_name = self.class.derive_project_name(url)
        raise Orn::Error, "Directory '#{project_name}' already exists" if File.exist?(project_name)

        @output_mode.status("Cloning orn project: #{project_name}\n")
        Dir.mkdir(project_name)
        scaffold_or_cleanup(
          project_name,
          url,
          base
        )
        print_next_steps(project_name, base)
        nil
      end

      # Derives the project directory name from a repo URL: the last
      # slash-separated segment with any .git suffix stripped.
      def self.derive_project_name(url)
        name = url.split("/").last.to_s.delete_suffix(".git")
        raise Orn::Error, "Could not derive project name from URL: #{url}" if name.empty?

        name
      end

      private

      def scaffold_or_cleanup(project_dir, url, base)
        Setup.clone_into(
          @output_mode,
          project_dir,
          project_dir,
          url,
          base
        )
      rescue StandardError
        FileUtils.rm_rf(project_dir)
        raise
      end

      def print_next_steps(project_name, base)
        @output_mode.status("\nDone. Project created at ./#{project_name}")
        @output_mode.status("Base worktree: #{project_name}/#{base}/")
        @output_mode.status("\nNext steps:")
        @output_mode.status("  cd #{project_name}/#{base}")
        @output_mode.status("  orn wt new feature/your-branch")
      end
    end
  end
end
