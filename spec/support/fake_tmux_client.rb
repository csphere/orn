# frozen_string_literal: true

# Recording stand-in for Orn::Tmux::Client. Every verb call is recorded in
# `calls` for domain-level assertions; verb names in `fail_on` raise
# Orn::Error after recording, so specs exercise failure paths without a tmux
# server. Query verbs return settable state, so partial-failure sequences are
# expressible (e.g. a window that exists while its agent pane is missing).
class FakeTmuxClient
  attr_reader :calls
  attr_accessor :fail_on,
    :windows,          # {"session" => ["main", "feat"]} backs window_exists?/list_windows
    :panes,            # {"session" => [PaneMetadata]}   backs list_panes_metadata
    :all_panes,        # [PaneMetadata] or nil            backs list_all_panes_metadata
    :borrowed,         # [BorrowedPane]                   backs list_borrowed_panes
    :sessions,         # ["session"]                      backs session_exists?
    :session_infos,    # [SessionInfo]                    backs list_sessions
    :session_paths,    # {"session" => "/path"}           backs session_path
    :client_session,   # String or nil                    backs client_session
    :active_panes,     # {"session:window" => pane_id}    backs active_pane
    :pane_commands,    # {"session:window" => command}    backs pane_command
    :pane_locations,   # {pane_id => [session, window]}   backs current_session_window
    :captures          # {pane_id => text}                backs capture_pane

  # Collaborators (e.g. the sandbox CLI) take the client's output mode.
  def output_mode
    Orn::OutputMode.quiet
  end

  def initialize(fail_on: [])
    @fail_on = fail_on
    @calls = []
    @windows = {}
    @panes = {}
    @all_panes = []
    @borrowed = []
    @sessions = []
    @session_infos = []
    @session_paths = {}
    @client_session = nil
    @active_panes = {}
    @pane_commands = {}
    @pane_locations = {}
    @captures = {}
  end

  # -- sessions --

  def ensure_session(session, path, default_window_name = nil)
    record(
      :ensure_session,
      session,
      path.to_s,
      default_window_name
    )
  end

  def session_exists?(session)
    record(:session_exists?, session)
    @sessions.include?(session)
  end

  def session_path(session)
    record(:session_path, session)
    @session_paths[session]
  end

  def list_sessions
    record(:list_sessions)
    @session_infos
  end

  def switch_client(session, window)
    record(:switch_client, session, window)
  end

  # -- windows --

  def create_window(session, name, _path, _layout, **)
    record(:create_window, session, name)
  end

  def new_window_running(session, name, path, command)
    record(
      :new_window_running,
      session,
      name,
      path.to_s,
      command
    )
  end

  def send_line(pane, line)
    record(:send_line, pane, line)
  end

  def window_exists?(session, name)
    record(:window_exists?, session, name)
    @windows.fetch(session, []).include?(name)
  end

  def pane_command(session, window)
    record(:pane_command, session, window)
    @pane_commands["#{session}:#{window}"]
  end

  def select_window(session, name)
    record(:select_window, session, name)
  end

  def kill_window(session, name)
    record(:kill_window, session, name)
  end

  def list_windows(session)
    record(:list_windows, session)
    @windows.fetch(session, [])
  end

  def reorder_windows(session, base_branch)
    record(:reorder_windows, session, base_branch)
  end

  # -- panes --

  def list_panes_metadata(session)
    record(:list_panes_metadata, session)
    @panes.fetch(session, [])
  end

  def list_all_panes_metadata
    record(:list_all_panes_metadata)
    @all_panes
  end

  def capture_pane(pane_id)
    record(:capture_pane, pane_id)
    @captures[pane_id]
  end

  def select_pane(pane)
    record(:select_pane, pane)
  end

  def resize_pane_width(pane, percentage)
    record(:resize_pane_width, pane, percentage)
  end

  def active_pane(session, window)
    record(:active_pane, session, window)
    @active_panes["#{session}:#{window}"]
  end

  def current_session_window(pane)
    record(:current_session_window, pane)
    @pane_locations[pane]
  end

  # -- borrowing --

  def join_pane(src_pane, dst, width_pct:, focus:)
    record(
      :join_pane,
      src_pane,
      dst,
      width_pct,
      focus
    )
  end

  def break_pane(src_pane, session, name)
    record(
      :break_pane,
      src_pane,
      session,
      name
    )
  end

  def recreate_session_with_pane(pane, session, name)
    record(
      :recreate_session_with_pane,
      pane,
      session,
      name
    )
  end

  def set_pane_option(pane, name, value)
    record(
      :set_pane_option,
      pane,
      name,
      value
    )
  end

  def unset_pane_option(pane, name)
    record(:unset_pane_option, pane, name)
  end

  def list_borrowed_panes
    record(:list_borrowed_panes)
    @borrowed
  end

  # -- key bindings --

  def bind_key_guarded(key, condition, action)
    record(
      :bind_key_guarded,
      key,
      condition,
      action
    )
  end

  def unbind_key(key)
    record(:unbind_key, key)
  end

  # -- trust-gated window opening --

  def open_window(project, branch)
    record(:open_window, branch)
    mint_open_result(project, branch)
  end

  def open_window_with_layout(project, branch, _layout, _layout_source, **)
    record(:open_window_with_layout, branch)
    mint_open_result(project, branch)
  end

  def open_window_non_interactive(project, branch)
    record(:open_window_non_interactive, branch)
    mint_open_result(project, branch)
  end

  def count(name)
    @calls.count { |call| call.first == name }
  end

  private

  def record(name, *arguments)
    @calls << [name, *arguments]
    raise Orn::Error, "#{name} failed" if @fail_on.include?(name)
  end

  # Mirror the real post-condition: the branch window exists in the project's
  # session afterwards.
  def mint_open_result(project, branch)
    session = Orn::Session.session_name(project)
    (@windows[session] ||= []) << branch unless @windows.fetch(session, []).include?(branch)
    Orn::Tmux::OpenWindowResult.new(
      branch: branch,
      session: session
    )
  end
end
