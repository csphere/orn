# frozen_string_literal: true

module Orn
  module Tmux
    # Window ordering: keep each session's windows as [orn, base, sorted
    # worktrees].
    class Client
      # Enforce window order in `session`. Uses swap-window so it works
      # regardless of the base-index setting. `base_branch` is empty for the
      # global TUI, which pins no base.
      def reorder_windows(session, base_branch)
        windows = list_windows(session)
        return if windows.length <= 1

        apply_window_order(
          session,
          windows,
          desired_order(windows, base_branch)
        )
      end

      private

      # The target window order: the TUI window first, then the base branch,
      # then the remaining worktree windows alphabetically.
      def desired_order(windows, base_branch)
        desired = []
        desired << TUI_WINDOW if windows.include?(TUI_WINDOW)
        desired << base_branch if windows.include?(base_branch)
        rest = windows.reject { |name| name == TUI_WINDOW || name == base_branch }.sort
        desired.concat(rest)
      end

      # Swap windows into `desired` order one mismatch at a time, tracking the
      # live positions as each swap lands.
      def apply_window_order(session, windows, desired)
        desired.each_index do |desired_index|
          next if windows[desired_index] == desired[desired_index]

          current_index = windows.index(desired[desired_index])
          next unless current_index

          swap_window(
            Tmux.window_target(session, windows[desired_index]),
            Tmux.window_target(session, windows[current_index])
          )
          displaced_window = windows[desired_index]
          windows[desired_index] = windows[current_index]
          windows[current_index] = displaced_window
        end
      end

      # Swap two windows in place without following either; failures are
      # ignored (the order is cosmetic).
      def swap_window(src_target, dst_target)
        tmux_output(
          "swap-window",
          "-d",
          "-s",
          src_target,
          "-t",
          dst_target
        )
      end
    end
  end
end
