# frozen_string_literal: true

require "json"

module Orn
  module Commands
    # Human/JSON output helpers shared across commands: pretty JSON and the
    # bordered worktree table.
    module Output
      def self.print_json(data)
        puts JSON.pretty_generate(data)
      end

      # Runs the given block for each branch, printing each success immediately
      # (unless json mode) via `printer` and collecting failures instead of
      # aborting the batch. Returns [results, errors].
      def self.run_multi_branch(output_mode, branches, printer)
        results = []
        errors = []
        branches.each do |branch|
          result = yield(branch)
          printer.call(result) unless output_mode.json
          results << result
        rescue Orn::Error => e
          warn "error: #{branch}: #{e.message}"
          errors << "#{branch}: #{e.message}"
        end
        [results, errors]
      end

      # Prints the JSON array (in json mode) and raises with a failure count
      # when any branch in the batch errored.
      def self.finish_multi_branch(output_mode, json_results, errors, total)
        print_json(json_results) if output_mode.json
        return if errors.empty?

        raise Orn::Error, "failed to remove #{errors.length} of #{total} worktrees"
      end

      # Renders worktree `rows` (each an array of cell strings) as a table
      # headed by the repo name, or a "No worktrees found" notice when empty.
      def self.worktree_table(repo, headers, rows)
        if rows.empty?
          puts "No worktrees found"
          return
        end

        puts "Worktrees in #{repo}:\n\n"
        puts render_table(headers, rows)
      end

      # A rounded-border table (single source; a richer renderer can replace it
      # later without changing callers). Public so commands with their own
      # headers (e.g. `sbx list`) can render without the worktree framing.
      def self.render_table(headers, rows)
        widths = column_widths(headers, rows)
        [
          border("╭", "┬", "╮", widths),
          row_line(headers, widths),
          border("├", "┼", "┤", widths),
          *rows.map { |row| row_line(row, widths) },
          border("╰", "┴", "╯", widths)
        ].join("\n")
      end

      def self.column_widths(headers, rows)
        headers.each_index.map do |index|
          [headers[index], *rows.map { |row| row[index] }].map(&:length).max
        end
      end

      def self.border(left, joint, right, widths)
        segments = widths.map { |width| "─" * (width + 2) }
        "#{left}#{segments.join(joint)}#{right}"
      end

      def self.row_line(cells, widths)
        padded = cells.each_index.map { |index| " #{cells[index].to_s.ljust(widths[index])} " }
        "│#{padded.join("│")}│"
      end

      private_class_method :column_widths, :border, :row_line
    end
  end
end
