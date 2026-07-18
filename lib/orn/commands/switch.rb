# frozen_string_literal: true

module Orn
  module Commands
    # `orn switch`: land on a branch's tmux window, creating whatever is missing
    # along the way (window, worktree, remote fetch, or a brand-new branch with
    # an optional sandbox). The sandbox-aware branches live in SwitchSandbox
    # (see switch_sandbox.rb). The TUI hub pane-return at the top of case 1 is a
    # follow-up.
    class Switch
      # How far switch had to go to land on the branch.
      Result = Data.define(:branch, :action, :base, :worktree_path, :sandbox_name, :host_ports) do
        # A minimal result with all optional fields empty.
        def self.simple(branch, action)
          new(
            branch: branch,
            action: action,
            base: nil,
            worktree_path: nil,
            sandbox_name: nil,
            host_ports: []
          )
        end

        # JSON shape: omit nil / empty optionals.
        def to_json_hash
          hash = {
            "branch" => branch,
            "action" => action.to_s
          }
          hash["base"] = base if base
          hash["worktree_path"] = worktree_path if worktree_path
          hash["sandbox_name"] = sandbox_name if sandbox_name
          hash["host_ports"] = host_ports.map(&:to_json_hash) unless host_ports.empty?
          hash
        end
      end

      def initialize(output_mode:)
        @output_mode = output_mode
      end

      # Resolves the branch through four escalating cases (window exists,
      # worktree exists, remote branch exists, brand new). `sbx` only affects
      # case 4; an existing sandbox is reattached in case 2 regardless.
      def perform(project, branch, base_override, sbx)
        session = Orn::Session.session_name(project)
        wt_path = project.worktree_path(branch)

        # Case 1: tmux window exists, just switch to it.
        if Orn::Tmux.window_exists?(@output_mode, session, branch)
          Orn::Tmux.select_window(@output_mode, session, branch)
          return Result.simple(branch, :switched)
        end

        # Case 2: worktree exists but window doesn't, reopen (reattaching the
        # branch's sandbox when one still exists).
        return reopen(project, branch) if File.exist?(wt_path)

        # Case 3: branch exists on the remote, fetch and create.
        @output_mode.status("Checking remote for #{branch}...")
        worktree = Orn::Git::Worktree.new(
          root: project.root,
          output_mode: @output_mode
        )
        if worktree.remote_branch_exists?("origin", branch)
          Wt::New.create(@output_mode, project, branch, nil)
          Orn::Tmux.open_window(@output_mode, project, branch)
          return Result.simple(branch, :fetched)
        end

        # Case 4: branch doesn't exist anywhere, create from base.
        if sbx
          SwitchSandbox.create_with_sandbox(@output_mode, project, branch, base_override)
        else
          create_plain(project, branch, base_override)
        end
      end

      def run(branch, base_override: nil, sbx: false)
        Orn::Git::BranchName.new(branch).validate!
        Orn::Git::BranchName.new(base_override).validate! if base_override

        project = Orn::Git::Project.discover
        project = Orn::Session.check_collision(@output_mode, project)
        result = perform(project, branch, base_override, sbx)
        emit(result)
      end

      private

      # Case 2: reopen the window. When the branch's sandbox still exists, reopen
      # with the sbx layout, republish ports, and rerun the start command.
      def reopen(project, branch)
        @output_mode.status("Reopening window for #{branch}...")
        sbx_name = project.sandbox_name(branch)
        if Orn::Sandbox.exists?(@output_mode, sbx_name)
          return SwitchSandbox.reopen_with_sandbox(@output_mode, project, branch, sbx_name)
        end

        Orn::Tmux.open_window(@output_mode, project, branch)
        Result.simple(branch, :reopened)
      end

      # Case 4 without a sandbox: new worktree from base plus a tmux window.
      def create_plain(project, branch, base_override)
        wt_result = Wt::New.create(@output_mode, project, branch, base_override)
        Orn::Tmux.open_window(@output_mode, project, branch)
        Result.new(
          branch: wt_result.branch,

          action: :created,

          base: wt_result.base,
          worktree_path: wt_result.worktree_path,

          sandbox_name: nil,

          host_ports: []
        )
      end

      def emit(result)
        return Commands::Output.print_json(result.to_json_hash) if @output_mode.json

        print_action(result)
        puts "Sandbox: #{result.sandbox_name}" if result.sandbox_name
        result.host_ports.each { |mapping| puts "Port: #{mapping}" }
      end

      def print_action(result)
        case result.action
        when :switched then puts "Switched to window: #{result.branch}"
        when :fetched then puts "Fetched from remote and opened: #{result.branch}"
        when :reopened then puts "Reopened window for #{result.branch}"
        when :created then print_created(result)
        end
      end

      def print_created(result)
        puts "Branch: #{result.branch}"
        puts "Base: #{result.base}" if result.base
        puts "Path: #{result.worktree_path}" if result.worktree_path
      end
    end
  end
end
