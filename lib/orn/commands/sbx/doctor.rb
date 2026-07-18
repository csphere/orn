# frozen_string_literal: true

module Orn
  module Commands
    module Sbx
      # `orn sbx doctor`: diagnostic checks for the sandbox environment (sbx CLI,
      # docker, colima, git identity, template, kits, build args, ssh, github
      # secret).
      class Doctor
        Result = Data.define(:checks, :all_passed) do
          def to_json_hash
            {
              "checks" => checks.map(&:to_json_hash),
              "all_passed" => all_passed
            }
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run_inner(project)
          sbx_config = project.config.require_sbx!
          checks = Orn::Sandbox.doctor(@output_mode, sbx_config, project.root)
          Result.new(
            checks: checks,
            all_passed: checks.all?(&:passed)
          )
        end

        def run
          project = Orn::Git::Project.discover
          result = run_inner(project)
          emit(result)
        end

        private

        def emit(result)
          return Commands::Output.print_json(result.to_json_hash) if @output_mode.json

          result.checks.each { |check| puts "#{icon(check)} #{check.name}: #{check.message}" }
          puts "\nSome checks failed. Fix the issues above and try again." unless result.all_passed
        end

        def icon(check)
          return "[ok]" if check.passed
          return "[--]" if check.kind == :warning

          "[!!]"
        end
      end
    end
  end
end
