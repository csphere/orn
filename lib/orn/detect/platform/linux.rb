# frozen_string_literal: true

module Orn
  module Detect
    module Platform
      # Linux foreground job discovery via `/proc`.
      module Linux
        # /proc/pid/stat fields after the "(comm)" column, 0-indexed starting
        # at state (file field 3). pgrp is file field 5, tpgid is file field 8.
        STAT_FIELD_PGRP = 2
        STAT_FIELD_TPGID = 5

        DEFAULT_PROC_ROOT = "/proc"

        # The foreground job on `child_pid`'s controlling terminal: read the
        # pane process's `tpgid`, then scan `/proc` for every process whose
        # `pgrp` matches it. `proc_root:` is a test seam; production always
        # uses the default.
        def self.foreground_job(child_pid, proc_root: DEFAULT_PROC_ROOT)
          child_stat = read_stat(child_pid, proc_root)
          return nil if child_stat.nil?

          tpgid = parse_tpgid(child_stat)
          return nil if tpgid.nil?

          processes = collect_group(
            child_pid,
            child_stat,
            tpgid,
            proc_root
          )
          return nil if processes.empty?

          Orn::Detect::ForegroundJob.new(
            process_group_id: tpgid,
            processes: processes
          )
        end

        # Every process in `/proc` whose pgrp matches `tpgid`, reusing the
        # already-read stat for `child_pid`.
        def self.collect_group(child_pid, child_stat, tpgid, proc_root)
          proc_pids(proc_root).filter_map do |pid|
            stat = pid == child_pid ? child_stat : read_stat(pid, proc_root)
            next if stat.nil?

            parsed = parse_pgrp_and_comm(stat)
            next if parsed.nil?

            pgrp, comm = parsed
            next if pgrp != tpgid

            Orn::Detect::ForegroundProcess.new(
              pid: pid,
              name: comm,
              argv: read_argv(pid, proc_root)
            )
          end
        end

        # The `index`-th whitespace-separated field after the `(comm)` column.
        # Splitting after the last `)` is immune to spaces and parens in comm.
        def self.stat_field(stat, index)
          close = stat.rindex(")")
          return nil if close.nil?

          stat[(close + 1)..].split(/\s+/).reject(&:empty?)[index]
        end

        # The terminal's foreground process group id from a stat line; nil when
        # the process has no controlling terminal (`tpgid` is `-1`).
        def self.parse_tpgid(stat)
          field = stat_field(stat, STAT_FIELD_TPGID)
          return nil if field.nil?

          tpgid = Integer(field, exception: false)
          return nil if tpgid.nil? || tpgid <= 0

          tpgid
        end

        # A process's [group id, command name] from its stat line.
        def self.parse_pgrp_and_comm(stat)
          open = stat.index("(")
          close = stat.rindex(")")
          return nil if open.nil? || close.nil?

          comm = stat[(open + 1)...close]
          field = stat_field(stat, STAT_FIELD_PGRP)
          pgrp = field.nil? ? nil : Integer(field, exception: false)
          return nil if pgrp.nil?

          [pgrp, comm]
        end

        def self.read_stat(pid, proc_root)
          File.read("#{proc_root}/#{pid}/stat")
        rescue SystemCallError
          nil
        end

        # Numeric entries under /proc (process ids).
        def self.proc_pids(proc_root)
          Dir.children(proc_root).filter_map { |name| Integer(name, exception: false) }
        rescue SystemCallError
          []
        end

        # Argv from `/proc/pid/cmdline` (NUL-separated); nil for kernel threads
        # and unreadable processes.
        def self.read_argv(pid, proc_root)
          raw = File.binread("#{proc_root}/#{pid}/cmdline")
          return nil if raw.empty?

          args = raw.split("\0").reject(&:empty?).map { |arg| arg.force_encoding("UTF-8").scrub }
          args.empty? ? nil : args
        rescue SystemCallError
          nil
        end

        private_class_method :collect_group,
          :read_stat,
          :proc_pids,
          :read_argv
      end
    end
  end
end
