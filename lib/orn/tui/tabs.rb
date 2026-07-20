# frozen_string_literal: true

module Orn
  module TUI
    # The hub window's agent tabs: which worktree agent panes are open as
    # tabs, which one is visible, and the tmux borrowing that carries out each
    # change. Owns both the tab list and the tmux effects (through Hub) so the
    # two cannot drift apart silently. `hub` is the effects layer; specs pass
    # a fake to exercise the state transitions without tmux.
    #
    # Failure invariant: when a tmux call fails mid-operation, the tab
    # involved is dropped or demoted to hidden, never left marked visible, and
    # the failure is reported through `on_error`. tmux itself may keep
    # leftovers (a tagged pane, a stale key binding); the startup pass
    # (Hub#reconcile plus Hub#remove_bindings) and the periodic prune against
    # the live pane listing clean those up.
    class Tabs
      attr_reader :hub_pane,
        :hub_location,
        :visible_index
      attr_accessor :agent_focused

      def initialize(hub:, hub_pane:, hub_location:, on_error: nil)
        @hub_pane = hub_pane
        @hub_location = hub_location
        @hub = hub
        @on_error = on_error
        @tabs = []
        @visible_index = nil
        @agent_focused = false
      end

      def visible
        @visible_index && @tabs[@visible_index]
      end

      def tab_index_for(root, branch)
        @tabs.index { |tab| tab.root.to_s == root.to_s && tab.branch == branch }
      end

      # Open a new tab for a worktree's agent pane and make it visible,
      # hiding the previously visible tab. Returns false (reporting the
      # error) when borrowing the pane fails; no tab is added then.
      def open(root:, session:, base_branch:, branch:)
        return false unless @hub_pane

        hide_visible
        tab = @hub.open_tab(
          root: root,
          session: session,
          base_branch: base_branch,
          branch: branch,
          hub_pane: @hub_pane
        )
        @tabs.push(tab)
        @visible_index = @tabs.length - 1
        install_bindings_for_visible
        true
      rescue Orn::Error => e
        report(e.message)
        false
      end

      # Bring an already-open tab to front, hiding the visible one. A tab
      # whose pane cannot be borrowed is dropped (reporting the error) rather
      # than kept in an unknown state; returns false then.
      def show(index)
        return false unless @hub_pane

        hide_visible
        @hub.show_tab(@tabs[index], @hub_pane)
        @visible_index = index
        install_bindings_for_visible
        true
      rescue Orn::Error => e
        report(e.message)
        remove_tab(index)
        false
      end

      # Hide the visible tab's pane (returns home); the tab stays open. The
      # tab is unmarked as visible even when the return fails: the pane stays
      # tagged in tmux, so the startup reconcile can still return it.
      def hide_visible
        index = @visible_index
        @visible_index = nil
        return unless index

        @hub.hide_tab(@tabs[index])
      rescue Orn::Error => e
        report(e.message)
      end

      # Close a tab, hiding it first when it is the visible one. The agent
      # keeps running in its home window.
      def close(index)
        hide_visible if @visible_index == index
        remove_tab(index)
        @hub.remove_bindings if @visible_index.nil?
      end

      # Hide and forget every tab; called when the TUI exits.
      def close_all
        hide_visible
        @tabs.clear
        @visible_index = nil
        @hub.remove_bindings
      end

      # Show the next or previous open tab. Returns true when the visible tab
      # changed, so the caller can follow it with the sidebar selection.
      def cycle(forward)
        target = cycle_index(forward)
        return false if target.nil? || target == @visible_index

        show(target)
      end

      # Drop tabs whose panes no longer exist (closed underneath us), tearing
      # down the key bindings when the visible tab was among them.
      def prune_dead_tabs(all_panes)
        had_visible = !@visible_index.nil?
        index = 0
        while index < @tabs.length
          if tab_pane_alive?(@tabs[index], all_panes)
            index += 1
          else
            remove_tab(index)
          end
        end
        @hub.remove_bindings if had_visible && @visible_index.nil?
      end

      # A visible tab's pane can be moved out of the hub behind our back
      # (e.g. `orn switch` returned it home). Demote such a tab to hidden and
      # tear down the key bindings.
      def demote_visible_if_moved(all_panes)
        tab = visible
        return unless @hub_location && tab

        hub_session, hub_window = @hub_location
        in_hub = all_panes.any? do |pane|
          pane.pane_id == tab.pane_id &&
            pane.session_name == hub_session &&
            pane.window_name == hub_window
        end
        return if in_hub

        @visible_index = nil
        @hub.remove_bindings
      end

      private

      def install_bindings_for_visible
        tab = visible
        return unless @hub_location && @hub_pane && tab

        hub_session, hub_window = @hub_location
        @hub.install_bindings(
          hub_session,
          hub_window,
          @hub_pane,
          tab.pane_id
        )
      rescue Orn::Error => e
        report(e.message)
      end

      def remove_tab(index)
        @tabs.delete_at(index)
        @visible_index = adjust_visible_after_remove(@visible_index, index)
      end

      # The tab index reached by cycling forward or backward from the visible
      # tab (from the ends when none is visible); nil when there are no tabs.
      def cycle_index(forward)
        length = @tabs.length
        return nil if length.zero?

        current = @visible_index
        if current.nil?
          forward ? 0 : length - 1
        elsif forward
          (current + 1) % length
        else
          (current + length - 1) % length
        end
      end

      # The visible-tab index after removing the tab at `removed`.
      def adjust_visible_after_remove(visible, removed)
        return visible if visible.nil?
        return nil if visible == removed

        visible > removed ? visible - 1 : visible
      end

      def tab_pane_alive?(tab, all_panes)
        all_panes.any? { |pane| pane.pane_id == tab.pane_id }
      end

      def report(message)
        @on_error&.call(message)
      end
    end
  end
end
