# frozen_string_literal: true

module Orn
  module Detect
    module Platform
      # macOS foreground job discovery via `ps`: shell out for the foreground process group
      # rather than a libproc/sysctl FFI. The
      # argv space-join is lossy for tokens containing spaces; acceptable until
      # a detection case regresses.
      module Macos
        # The foreground process group id on `pid`'s controlling terminal via
        # `ps -o tpgid=`; nil when the process has no terminal or the query
        # fails.
        def self.foreground_process_group_id(pid)
          return nil if pid.zero?

          result = run_ps(
            "-o",
            "tpgid=",
            "-p",
            pid.to_s
          )
          return nil if result.nil? || !result.success?

          tpgid = Integer(result.stdout.strip, exception: false)
          return nil if tpgid.nil? || tpgid <= 0

          tpgid
        end

        # The foreground job on `child_pid`'s controlling terminal: resolve the
        # foreground group id, then list every process in that group.
        def self.foreground_job(child_pid)
          tpgid = foreground_process_group_id(child_pid)
          return nil if tpgid.nil?

          result = run_ps(
            "-o",
            "pid=,comm=,args=",
            "-g",
            tpgid.to_s
          )
          return nil if result.nil? || !result.success?

          processes = parse_ps_group(result.stdout)
          return nil if processes.empty?

          Orn::Detect::ForegroundJob.new(
            process_group_id: tpgid,
            processes: processes
          )
        end

        def self.parse_ps_group(output)
          output.each_line.filter_map { |line| parse_ps_line(line) }
        end

        # One `pid comm args...` line: pid, the command (single token), and the
        # remaining space-joined argv (nil when absent).
        def self.parse_ps_line(line)
          fields = line.strip.split(/\s+/, 3)
          return nil if fields.length < 2

          pid = Integer(fields[0], exception: false)
          return nil if pid.nil?

          argv = fields[2]&.split(/\s+/)
          Orn::Detect::ForegroundProcess.new(
            pid: pid,
            name: fields[1],
            argv: argv
          )
        end

        def self.run_ps(*args)
          Orn::Cmd.new(output_mode: Orn::OutputMode.quiet).output("ps", *args)
        rescue Orn::Error
          nil
        end

        private_class_method :run_ps
      end
    end
  end
end
