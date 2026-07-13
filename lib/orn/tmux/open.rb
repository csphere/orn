# frozen_string_literal: true

module Orn
  module Tmux
    # Serializable result of opening a worktree window.
    OpenWindowResult = Data.define(:branch, :session)

    # Open the tmux window for `branch` using the project's configured layout,
    # prompting for trust approval when the layout comes from an untrusted
    # source.
    def self.open_window(output_mode, project, branch)
      open_window_with_layout(
        output_mode, project, branch,
        project.config.layout, project.config.layout_source, template_vars: {}
      )
    end

    # Open the window with an explicit layout and template variables, checking
    # trust for `layout_source` first.
    def self.open_window_with_layout(output_mode, project, branch, layout, layout_source, template_vars: {})
      trusted = Orn::Trust.check_trust(output_mode, project.root, layout, layout_source)
      open_checked_window(output_mode, project, branch, trusted, template_vars)
    end

    # Open a worktree window without ever prompting for trust approval;
    # untrusted project pane commands fail instead. For the TUI, where a prompt
    # would garble the screen.
    def self.open_window_non_interactive(output_mode, project, branch)
      trusted = Orn::Trust.check_trust_non_interactive(
        output_mode, project.root, project.config.layout, project.config.layout_source
      )
      open_checked_window(output_mode, project, branch, trusted, {})
    end

    # Create the worktree window once the layout has passed a trust check.
    def self.open_checked_window(output_mode, project, branch, layout, template_vars)
      session = Session.session_name(project)
      output_mode.status("Opening tmux window...")
      create_window(
        output_mode, session, branch, project.worktree_path(branch), layout,
        template_vars: template_vars, default_window_name: project.config.base
      )
      OpenWindowResult.new(branch: branch, session: session)
    end

    private_class_method :open_checked_window
  end
end
