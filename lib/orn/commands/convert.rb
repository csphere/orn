# frozen_string_literal: true

require "fileutils"

module Orn
  module Commands
    # `orn convert`: turn a standard git repo into a bare-worktree project in
    # place by moving it aside as a backup and re-cloning from origin. Guarded
    # by strict preconditions so no local-only state can be lost.
    class Convert
      # Values discovered while validating the repo, reused by convert so it
      # does not re-run the git commands that produced them.
      Guards = Data.define(:origin_url, :current_branch)

      def initialize(output_mode:)
        @output_mode = output_mode
        @cmd = Orn::Cmd.new(output_mode: output_mode)
      end

      def run(base)
        run_in(Dir.pwd, base)
      end

      def run_in(dir, base)
        convert(
          dir,
          base,
          check_guards(dir, base)
        )
      end

      # Runs every conversion precondition, failing fast on the first violation,
      # and returns the values it discovered.
      def check_guards(dir, base)
        check_is_git_repo!(dir)
        check_not_bare_worktree!(dir)
        check_no_submodules!(dir)
        check_no_extra_worktrees!(dir)
        check_clean_working_tree!(dir)
        origin_url = check_origin_remote!(dir)
        current_branch = check_head_not_detached!(dir, base)
        check_no_unpushed_commits!(dir)
        check_no_local_only_branches!(dir)
        Guards.new(
          origin_url: origin_url,
          current_branch: current_branch
        )
      end

      # Picks the base branch: an explicit `base` wins (validated); otherwise the
      # current branch, which must match the remote default branch when known.
      def resolve_base_branch(dir, base, current_branch)
        if base
          Orn::Git::BranchName.new(base).validate!
          return base
        end

        head_branch = current_branch || read_current_branch(dir)
        remote_default = read_remote_default_branch(dir)
        return head_branch if remote_default.nil? || remote_default == head_branch

        raise Orn::Error,
          "Current branch '#{head_branch}' does not match the remote default branch " \
          "'#{remote_default}'.\nUse --base #{remote_default} to specify the base branch explicitly."
      end

      private

      def check_is_git_repo!(dir)
        return if File.exist?(File.join(dir, ".git"))

        raise Orn::Error, "Not inside a git repository (no .git found)"
      end

      def check_not_bare_worktree!(dir)
        return unless File.file?(File.join(dir, ".git"))

        raise Orn::Error, "Already a bare worktree project (.git is a pointer file)"
      end

      def check_no_submodules!(dir)
        return unless File.exist?(File.join(dir, ".gitmodules"))

        raise Orn::Error, "orn does not yet support repos with submodules"
      end

      def check_no_extra_worktrees!(dir)
        porcelain = git_run(dir, "worktree", "list", "--porcelain").stdout
        return unless porcelain.lines.count { |line| line.start_with?("worktree ") } > 1

        raise Orn::Error, "Repository has multiple worktrees; remove extra worktrees before converting"
      end

      # Rejects staged or unstaged changes to tracked files; untracked files are
      # allowed (the backup preserves them).
      def check_clean_working_tree!(dir)
        tracked_changes = git_run(dir, "status", "--porcelain").stdout.lines.any? { |line| !line.start_with?("?") }
        return unless tracked_changes

        raise Orn::Error, "Working tree has uncommitted changes; commit or stash them before converting"
      end

      def check_origin_remote!(dir)
        result = git_output(
          dir,
          "config",
          "--get",
          "remote.origin.url"
        )
        return result.stdout.strip if result.success?

        raise Orn::Error, "No 'origin' remote configured; add one with: git remote add origin <url>"
      end

      # Returns the current branch name, nil when HEAD is detached but `base` was
      # given, and raises when detached without `base`.
      def check_head_not_detached!(dir, base)
        result = git_output(
          dir,
          "symbolic-ref",
          "--short",
          "HEAD"
        )
        return result.stdout.strip if result.success?
        return nil unless base.nil?

        raise Orn::Error, "HEAD is detached; use --base to specify the base branch"
      end

      # Fails when HEAD is ahead of its upstream. Passes silently when HEAD has
      # no upstream (that case is caught by check_no_local_only_branches!).
      def check_no_unpushed_commits!(dir)
        result = git_output(
          dir,
          "log",
          "@{upstream}..HEAD",
          "--oneline"
        )
        return unless result.success? && !result.stdout.strip.empty?

        raise Orn::Error, "Branch has unpushed commits; push them before converting"
      end

      def check_no_local_only_branches!(dir)
        result = git_run(dir, "for-each-ref", "--format=%(refname:short) %(upstream)", "refs/heads/")
        local_only = result.stdout.lines.filter_map do |line|
          parts = line.split
          parts.first if parts.length == 1
        end
        return if local_only.empty?

        raise Orn::Error, "Local-only branches with no upstream: #{local_only.join(", ")}"
      end

      def read_current_branch(dir)
        git_run(dir, "symbolic-ref", "--short", "HEAD").stdout.strip
      end

      # The remote default branch from refs/remotes/origin/HEAD, or nil when the
      # symref is not set locally.
      def read_remote_default_branch(dir)
        result = git_output(
          dir,
          "symbolic-ref",
          "refs/remotes/origin/HEAD"
        )
        return nil unless result.success?

        prefix = "refs/remotes/origin/"
        full_ref = result.stdout.strip
        full_ref.start_with?(prefix) ? full_ref.delete_prefix(prefix) : nil
      end

      # Moves the repo to a sibling <dir>.pre-orn backup, re-clones from origin
      # into a fresh dir, and restores the backup on failure. The backup is kept
      # on success so the user can recover gitignored files.
      def convert(dir, base, guards)
        base_branch = resolve_base_branch(
          dir,
          base,
          guards.current_branch
        )
        project_name = Orn::Commands::Clone.derive_project_name(guards.origin_url)
        dir_name = directory_name(dir)
        backup_path = File.join(File.dirname(dir), "#{dir_name}.pre-orn")
        reject_existing_backup!(backup_path)

        @output_mode.status("Converting repo: #{project_name}\n")
        @output_mode.status("  Backing up to ../#{dir_name}.pre-orn/")
        FileUtils.mv(dir, backup_path)
        Dir.mkdir(dir)

        clone_or_restore(
          dir,
          project_name,
          guards.origin_url,
          base_branch,
          backup_path
        )
        print_next_steps(dir_name, base_branch)
        nil
      end

      def clone_or_restore(dir, project_name, origin_url, base_branch, backup_path)
        Setup.clone_into(
          @output_mode,
          dir,
          project_name,
          origin_url,
          base_branch
        )
      rescue StandardError
        FileUtils.rm_rf(dir)
        restore_backup!(backup_path, dir)
      end

      def restore_backup!(backup_path, dir)
        FileUtils.mv(backup_path, dir)
        raise Orn::Error, "Conversion failed; repository restored to original location"
      rescue SystemCallError
        raise Orn::Error, "Conversion failed; could not restore backup. Backup at: #{backup_path}"
      end

      def reject_existing_backup!(backup_path)
        return unless File.exist?(backup_path)

        raise Orn::Error, "Backup path already exists: #{backup_path}\nA previous conversion may have been interrupted."
      end

      def directory_name(dir)
        name = File.basename(dir)
        raise Orn::Error, "Cannot determine directory name" if name.empty? || name == "/"

        name
      end

      def print_next_steps(dir_name, base_branch)
        @output_mode.status("\nDone. Converted to orn project at ./#{dir_name}")
        @output_mode.status("Base worktree: #{dir_name}/#{base_branch}/")
        @output_mode.status("\nBackup: ../#{dir_name}.pre-orn/")
        @output_mode.status("  Check backup for gitignored files (.env, credentials, IDE configs)")
        @output_mode.status("  to copy into the new worktree. Delete backup when satisfied.")
      end

      def git_run(dir, *args)
        @cmd.run(
          "git",
          "-C",
          dir,
          *args
        )
      end

      def git_output(dir, *args)
        @cmd.output("git", "-C", dir, *args)
      end
    end
  end
end
