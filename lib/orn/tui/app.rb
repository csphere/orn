# frozen_string_literal: true

module Orn
  module TUI
    # One worktree row: git dirtiness, tmux window presence, and ahead/behind
    # counts relative to the base branch.
    WorktreeStatus = Data.define(
      :branch,
      :dirty,
      :has_window,
      :ahead,
      :behind
    )

    # Input mode. A non-`normal` mode renders a modal prompt line and captures
    # keys until confirmed or cancelled. `text` carries the typed branch name
    # (new-branch mode) or the branch being removed (confirm-remove mode).
    Mode = Data.define(:kind, :text) do
      def self.normal
        new(
          kind: :normal,
          text: nil
        )
      end

      def self.new_branch(input = "")
        new(
          kind: :new_branch,
          text: input
        )
      end

      def self.confirm_remove(branch)
        new(
          kind: :confirm_remove,
          text: branch
        )
      end

      def normal? = kind == :normal
      def new_branch? = kind == :new_branch
      def confirm_remove? = kind == :confirm_remove
      def input = text
      def branch = text
    end

    # State and actions for the per-project TUI: the worktree list with git and
    # agent status, and branch create/open/close/remove operations. A mutable
    # PORO the event loop drives and the renderer reads.
    class App
      include PollTiming

      # Cadence of agent-state detection, faster than the full worktree refresh.
      AGENT_REFRESH_INTERVAL = 1

      attr_accessor :entries,
        :selected,
        :repo_name,
        :error,
        :mode,
        :agent_states,
        :spinner_tick
      attr_reader :session, :base_branch

      # Build the app from a discovered project and run an initial refresh.
      def self.for_project(output_mode, project, client: nil)
        sbx = project.config.sbx
        agent_type = sbx&.agent_type && Orn::Detect.identify_agent(sbx.agent_type)
        app = new(
          output_mode: output_mode,
          root: project.root,
          session: Orn::Session.session_name(project),
          base_branch: project.config.base,
          repo_name: File.basename(project.root.to_s),
          symlinks: project.config.symlinks,
          sbx_agent_type: agent_type,
          client: client
        )
        app.refresh
        app
      end

      def initialize(output_mode:, root:, session:, base_branch:,
        repo_name: nil, symlinks: nil, sbx_agent_type: nil, client: nil)
        @output = output_mode
        @client = client || Orn::Tmux::Client.new(output_mode: output_mode)
        @root = root
        @session = session
        @base_branch = base_branch
        @repo_name = repo_name || File.basename(root.to_s)
        @symlinks = symlinks || Orn::Config::SymlinksConfig.new(
          base: [],
          root: []
        )
        @sbx_agent_type = sbx_agent_type
        @hub = Hub.new(client: @client)
        @entries = []
        @selected = 0
        @error = nil
        @mode = Mode.normal
        @agent_states = {}
        @spinner_tick = 0
        @last_refresh = monotonic
        @last_agent_refresh = monotonic
      end

      # Rebuild worktree rows from git and tmux (base branch first, then
      # alphabetical) and re-enforce the session's window order.
      def refresh
        worktree = Orn::Git::Worktree.new(
          root: @root,
          output_mode: @output
        )
        windows = @client.list_windows(@session)
        entries = worktree.entries.map { |branch| status_for(branch, windows) }
        entries.sort_by! { |entry| [entry.branch == @base_branch ? 0 : 1, entry.branch] }
        @entries = entries

        @selected = @entries.length - 1 if @selected >= @entries.length && !@entries.empty?
        @last_refresh = monotonic
        @client.reorder_windows(@session, @base_branch)
      end

      # Re-detect agent state for every pane in the session.
      def refresh_agents
        panes = @client.list_panes_metadata(@session)
        @agent_states = Orn::Detect.detect_all_panes(
          @client,
          panes,
          @sbx_agent_type
        )
        @last_agent_refresh = monotonic
      end

      # Run the agent and full refreshes when their intervals have elapsed.
      def maybe_refresh
        refresh_agents if monotonic - @last_agent_refresh >= AGENT_REFRESH_INTERVAL
        refresh if monotonic - @last_refresh >= REFRESH_INTERVAL
      end

      def any_agent_working?
        @agent_states.values.any? { |state| state.state == :working }
      end

      # Move the selection down, wrapping past the end.
      def move_down
        @selected = (@selected + 1) % @entries.length unless @entries.empty?
      end

      # Move the selection up, wrapping past the start.
      def move_up
        @selected = (@selected + @entries.length - 1) % @entries.length unless @entries.empty?
      end

      def clear_error
        @error = nil
      end

      # Switch to the selected worktree's window, creating a bare window (no
      # configured layout) when it has none.
      def open_selected
        entry = @entries[@selected]
        return unless entry

        branch = entry.branch
        return if !entry.has_window && !create_bare_window(branch)

        refresh
        select_window(branch)
      end

      # Kill the selected worktree's tmux window; the worktree stays on disk.
      def close_selected
        entry = @entries[@selected]
        return unless entry

        branch = entry.branch
        # Closing a worktree whose agent pane is borrowed by the hub first
        # returns the pane so the kill reaches it. A successful return also
        # recreates the home window, so the kill proceeds even though
        # entry.has_window (from the last refresh) still says false.
        returned = @hub.return_borrowed_for_branch(@session, branch)
        return if !entry.has_window && !returned

        kill_window_and_refresh(branch)
      end

      def start_new_branch
        @mode = Mode.new_branch
      end

      def start_remove
        entry = @entries[@selected]
        @mode = Mode.confirm_remove(entry.branch) if entry
      end

      def cancel_mode
        @mode = Mode.normal
      end

      def new_branch_push_char(char)
        @mode = Mode.new_branch(@mode.input + char) if @mode.new_branch?
      end

      def new_branch_pop_char
        @mode = Mode.new_branch(@mode.input[0...-1]) if @mode.new_branch?
      end

      # Create the entered branch's worktree, symlinks, and window, then focus
      # it. Starts from `origin/<branch>` when the branch exists on the remote,
      # otherwise from the base branch.
      def confirm_new_branch
        return unless @mode.new_branch?

        branch = @mode.input.strip
        @mode = Mode.normal
        return if branch.empty?

        create_branch(branch)
      end

      # Remove the confirmed worktree and its window. A hub-borrowed agent pane
      # is returned first so the window kill reaches it.
      def confirm_remove
        return unless @mode.confirm_remove?

        branch = @mode.branch
        @mode = Mode.normal

        @hub.return_borrowed_for_branch(@session, branch)
        return unless kill_window_before_remove(branch)

        remove_worktree(branch)
      end

      private

      def status_for(branch, windows)
        wt_path = File.join(@root.to_s, branch)
        ahead, behind = GitStats.ahead_behind(
          @output,
          wt_path,
          branch,
          @base_branch
        )
        WorktreeStatus.new(
          branch: branch,
          dirty: GitStats.dirty?(@output, wt_path),
          has_window: windows.include?(branch),
          ahead: ahead,
          behind: behind
        )
      end

      def create_branch(branch)
        # Same rules as the CLI commands: the branch becomes a filesystem
        # path and a tmux window target.
        Orn::Git::BranchName.new(branch).validate!
        wt_path = File.join(@root.to_s, branch)
        worktree = Orn::Git::Worktree.new(
          root: @root,
          output_mode: @output
        )
        start_point = resolve_start_point(worktree, branch)
        return if start_point.nil?

        build_worktree(
          worktree,
          branch,
          wt_path,
          start_point
        )
      rescue Orn::Error => e
        @error = e.message
      end

      # origin/<branch> when the branch is on the remote (fetching it first),
      # else the base branch. Nil signals a fetch failure already reported.
      def resolve_start_point(worktree, branch)
        return @base_branch unless worktree.remote_branch_exists?("origin", branch)

        worktree.fetch("origin", branch)
        "origin/#{branch}"
      rescue Orn::Error => e
        @error = e.message
        nil
      end

      def build_worktree(worktree, branch, wt_path, start_point)
        worktree.add(
          wt_path,
          branch,
          start_point
        )
        Orn::Symlink.apply(
          @output,
          @root,
          wt_path,
          @base_branch,
          @symlinks
        ) do |unignored|
          Orn::Symlink.add_to_gitignore_and_stage(
            @output,
            wt_path,
            unignored
          )
        end
        create_window(branch, wt_path)
        refresh
        select_window(branch)
      end

      def create_bare_window(branch)
        create_window(branch, File.join(@root.to_s, branch))
        true
      rescue Orn::Error => e
        @error = e.message
        false
      end

      def create_window(branch, wt_path)
        @client.create_window(
          @session,
          branch,
          wt_path,
          Orn::Config::Layout.of_columns([]),
          template_vars: {},
          default_window_name: @base_branch
        )
      end

      def select_window(branch)
        @client.select_window(@session, branch)
      rescue Orn::Error => e
        @error = e.message
      end

      def kill_window_and_refresh(branch)
        @client.kill_window(@session, branch)
        refresh
      rescue Orn::Error => e
        @error = e.message
      end

      # Kill the branch's window if it exists. Returns whether the removal
      # can continue; a failed kill records the error and returns false.
      def kill_window_before_remove(branch)
        return true unless @client.window_exists?(@session, branch)

        @client.kill_window(@session, branch)
        true
      rescue Orn::Error => e
        @error = e.message
        false
      end

      def remove_worktree(branch)
        wt_path = File.join(@root.to_s, branch)
        Orn::Git::Worktree.new(
          root: @root,
          output_mode: @output
        ).remove(wt_path)
        refresh
      rescue Orn::Error => e
        @error = e.message
      end
    end
  end
end
