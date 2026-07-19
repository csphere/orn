# frozen_string_literal: true

# Recording stand-in for the Hub tmux-effects layer behind Orn::TUI::Tabs.
# Every effect call is recorded for assertions; effect names in `fail_on`
# raise Orn::Error after recording, so specs exercise Tabs' failure paths
# without a tmux server. `open_tab` mints sequential pane ids ("%1", "%2").
class FakeHub
  attr_reader :calls
  attr_accessor :fail_on

  def initialize(fail_on: [])
    @fail_on = fail_on
    @calls = []
    @pane_counter = 0
  end

  def open_tab(_output_mode, root:, session:, base_branch:, branch:, hub_pane:)
    record(:open_tab, [branch, hub_pane])
    @pane_counter += 1
    Orn::TUI::Hub::Tab.new(
      root: root,
      session: session,
      base_branch: base_branch,
      branch: branch,
      pane_id: "%#{@pane_counter}"
    )
  end

  def show_tab(_output_mode, tab, _hub_pane)
    record(:show_tab, tab.branch)
  end

  def hide_tab(_output_mode, tab)
    record(:hide_tab, tab.branch)
  end

  def install_bindings(_output_mode, _hub_session, _hub_window, _hub_pane, agent_pane)
    record(:install_bindings, agent_pane)
  end

  def remove_bindings(_output_mode)
    record(:remove_bindings, nil)
  end

  def count(name)
    @calls.count { |call| call.first == name }
  end

  private

  def record(name, argument)
    @calls << [name, argument]
    raise Orn::Error, "#{name} failed" if @fail_on.include?(name)
  end
end
