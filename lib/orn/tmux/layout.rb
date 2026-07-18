# frozen_string_literal: true

module Orn
  module Tmux
    # Pure planning of a window's pane splits from a Layout config, decoupled
    # from running tmux. Panes are identified by their creation index (0 is the
    # window's initial pane). mod.rb walks the resulting Plan to issue the real
    # split-window calls.
    module Layout
      # One planned split-window call: split `target`, giving the new pane
      # (`result`) `percentage`% of the space. `direction` is :horizontal (new
      # pane beside the target, `-h`) or :vertical (below, `-v`).
      Split = Data.define(
        :direction,
        :target,
        :percentage,
        :result
      )

      # A command to type into a pane once splits are done and its shell is ready.
      PaneCommand = Data.define(:pane, :command)

      # Ordered splits and pane commands realizing a Layout; `focus_pane` gets
      # the final select-pane.
      Plan = Data.define(
        :splits,
        :commands,
        :focus_pane
      )

      # Size for the next split when `remaining` panes still have to fit in the
      # space being divided: the new pane takes remaining / (remaining + 1)
      # (rounded) so all panes end up equal after subsequent splits.
      def self.split_percentage(remaining)
        denominator = remaining + 1
        ((100 * remaining) + (denominator / 2)) / denominator
      end

      # Plan a columns layout: split columns off left to right, then split each
      # column's panes top to bottom.
      def self.plan_columns(columns)
        Planner.new.plan_columns(columns)
      end

      # Plan a rows layout: split rows off top to bottom; each row is either a
      # vertical stack of panes or nested columns split left to right.
      def self.plan_rows(rows)
        Planner.new.plan_rows(rows)
      end

      # Replace {{key}} placeholders in a pane command with values from `vars`;
      # unknown placeholders are left untouched.
      def self.substitute_template_vars(command, vars)
        vars.reduce(command) { |result, (key, value)| result.gsub("{{#{key}}}", value) }
      end

      # Builds a Plan by accumulating splits, pane commands, and the pane grid as
      # it walks the layout. One Planner is used per plan.
      class Planner
        def initialize
          @next_pane = 1
          @splits = []
          @commands = []
          @pane_grid = []
        end

        def plan_columns(columns)
          return empty_plan if columns.empty?

          column_roots = chain_split(
            0,
            columns.length,
            :horizontal
          )
          columns.each_with_index { |column, index| plan_pane_stack(column_roots[index], column.panes) }
          finish
        end

        def plan_rows(rows)
          return empty_plan if rows.empty?

          row_roots = chain_split(
            0,
            rows.length,
            :vertical
          )
          rows.each_with_index { |row, index| plan_row(row_roots[index], row) }
          finish
        end

        private

        def plan_row(root, row)
          unless row.columns?
            plan_pane_stack(root, row.panes)
            return
          end

          column_roots = chain_split(
            root,
            row.columns.length,
            :horizontal
          )
          row.columns.each_with_index { |column, index| plan_pane_stack(column_roots[index], column.panes) }
        end

        # Splits `root` vertically into one pane per command, records the pane
        # group, and queues the non-empty commands.
        def plan_pane_stack(root, pane_commands)
          panes = chain_split(
            root,
            pane_commands.length,
            :vertical
          )
          @pane_grid << panes
          pane_commands.each_with_index do |command, index|
            next if command.empty?

            @commands << PaneCommand.new(
              pane: panes[index],
              command: command
            )
          end
        end

        # Produces `count` panes starting at `root`, each split off the previous
        # in `direction`. Returns the pane list [root, ...].
        def chain_split(root, count, direction)
          panes = [root]
          previous = root
          (1...count).each do |i|
            new_pane = @next_pane
            @next_pane += 1
            @splits << Split.new(
              direction: direction,
              target: previous,
              percentage: Layout.split_percentage(count - i),
              result: new_pane
            )
            panes << new_pane
            previous = new_pane
          end
          panes
        end

        def finish
          Plan.new(
            splits: @splits,
            commands: @commands,
            focus_pane: @pane_grid.first.first
          )
        end

        def empty_plan
          Plan.new(
            splits: [],
            commands: [],
            focus_pane: 0
          )
        end
      end
      private_constant :Planner
    end
  end
end
