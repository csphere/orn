# frozen_string_literal: true

module Orn
  module Commands
    module Wt
      # `orn wt new`: create a worktree for a branch, from the remote branch when
      # it exists, otherwise branching off base. Worktree-only (no tmux window).
      class New
        Result = Data.define(:branch, :base, :worktree_path, :from_remote)

        # Reusable core: create the worktree (plus symlinks and blackboard
        # entry) in an already-discovered `project`. Shared with switch and
        # `wt open`.
        def self.create(output_mode, project, branch, base_override)
          base = base_override || project.config.base
          wt_path = project.worktree_path(branch)
          if File.exist?(wt_path)
            raise Orn::Error, "Worktree already exists at #{wt_path}\n  Use 'orn open #{branch}' to open it"
          end

          worktree = Orn::Git::Worktree.new(root: project.root, output_mode: output_mode)
          from_remote = create_worktree(output_mode, project, worktree, branch, base)
          apply_symlinks(output_mode, project, worktree, wt_path, base)
          Orn::Blackboard.ensure_dir(project.root)
          Orn::Blackboard.create_entry(project.root, branch)

          Result.new(branch: branch, base: base, worktree_path: wt_path.to_s, from_remote: from_remote)
        end

        # Fetches base, then creates the worktree from origin/<branch> when the
        # remote branch exists, otherwise from origin/<base>. Returns from_remote.
        def self.create_worktree(output_mode, project, worktree, branch, base)
          wt_path = project.worktree_path(branch)
          output_mode.status("Fetching origin/#{base}...")
          worktree.fetch("origin", base)

          from_remote = worktree.remote_branch_exists?("origin", branch)
          worktree.fetch("origin", branch) if from_remote
          start_point = from_remote ? "origin/#{branch}" : "origin/#{base}"
          output_mode.status("Creating worktree at #{wt_path}...")
          worktree.add(wt_path, branch, start_point)
          from_remote
        end

        def self.apply_symlinks(output_mode, project, worktree, wt_path, base)
          symlinks = project.config.symlinks
          output_mode.status("Creating symlinks...") if !symlinks.base.empty? || !symlinks.root.empty?
          Orn::Symlink.apply(output_mode, project.root, wt_path, base, symlinks) do |unignored|
            handle_unignored(output_mode, worktree, wt_path, unignored)
          end
        end

        # Symlink destinations must be gitignored. Interactively offer to add
        # them; otherwise (and in JSON mode) remove the new worktree and abort.
        def self.handle_unignored(output_mode, worktree, wt_path, unignored)
          if !output_mode.json && $stdin.tty?
            resolve_unignored_interactively(output_mode, worktree, wt_path, unignored)
          else
            safe_remove(worktree, wt_path)
            raise Orn::Error, unignored_message(unignored)
          end
        end

        def self.resolve_unignored_interactively(output_mode, worktree, wt_path, unignored)
          confirmed = Orn::Confirm.with_stdin_stderr { |reader, writer| Orn::Confirm.gitignore(unignored, reader, writer) }
          if confirmed
            Orn::Symlink.add_to_gitignore_and_stage(output_mode, wt_path, unignored)
          else
            safe_remove(worktree, wt_path)
            raise Orn::Error, "Aborted"
          end
        end

        def self.unignored_message(unignored)
          paths = unignored.map { |path| "'#{path}'" }.join(", ")
          noun = unignored.length > 1 ? "destinations" : "destination"
          pronoun = unignored.length > 1 ? "them" : "it"
          "symlink #{noun} not in .gitignore: #{paths}\n" \
            "Add #{pronoun} to .gitignore before running 'orn new'"
        end

        def self.safe_remove(worktree, wt_path)
          worktree.remove(wt_path)
        rescue Orn::Error
          nil
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run(branch, base_override: nil)
          Orn::Git::BranchName.new(branch).validate!
          Orn::Git::BranchName.new(base_override).validate! if base_override

          project = Orn::Git::Project.discover
          result = self.class.create(@output_mode, project, branch, base_override)
          emit(result)
        end

        private

        def emit(result)
          return Commands::Output.print_json(result.to_h) if @output_mode.json

          puts "Created worktree: #{result.worktree_path}"
          if result.from_remote
            puts "Branch: #{result.branch} (from remote)"
          else
            puts "Branch: #{result.branch} (based on #{result.base})"
          end
        end

        private_class_method :create_worktree, :apply_symlinks, :handle_unignored,
          :resolve_unignored_interactively, :unignored_message, :safe_remove
      end
    end
  end
end
