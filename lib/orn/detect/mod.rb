# frozen_string_literal: true

module Orn
  # Agent detection: identify which AI coding agent runs in a tmux pane and
  # what state it is in (idle, working, blocked). Agents and states are plain
  # symbols (`:claude`, `:working`); the manifest keys off the agent label.
  module Detect
    # Canonical agent labels, matching the bundled manifest ids.
    AGENTS = %i[claude pi codex gemini cursor devin amp kiro].freeze

    # Process-name aliases mapped to their canonical agent.
    AGENT_ALIASES = {
      "claude" => :claude,
      "claude-code" => :claude,
      "pi" => :pi,
      "codex" => :codex,
      "gemini" => :gemini,
      "cursor" => :cursor,
      "cursor-agent" => :cursor,
      "devin" => :devin,
      "devin-cli" => :devin,
      "amp" => :amp,
      "amp-local" => :amp,
      "kiro" => :kiro,
      "kiro-cli" => :kiro
    }.freeze

    # Activity states in ascending urgency order; the index is the priority
    # weight (`:blocked` outranks `:working` outranks `:idle`).
    AGENT_STATES = %i[unknown idle working blocked].freeze

    # Interpreters and shells that may wrap an agent script rather than be the
    # agent themselves.
    GENERIC_RUNTIMES = %w[node bun python python3 bash sh zsh].freeze
    # Container CLIs; an agent behind one of these runs inside a sandbox.
    CONTAINER_RUNTIMES = %w[docker sbx podman nerdctl].freeze
    # Runtime flags meaning "evaluate inline code": later args are code, not a
    # script path, so wrapped-agent detection must bail out.
    EVAL_FLAGS = %w[-e -c -p].freeze
    # Extensions stripped before matching a process or script name.
    STRIPPABLE_EXTENSIONS = %w[.exe .cmd .bat .ps1 .js].freeze

    # The foreground process group on a pane's controlling terminal, with its
    # member processes.
    ForegroundJob = Data.define(:process_group_id, :processes)

    # One process within a ForegroundJob; `argv` is nil when unreadable.
    ForegroundProcess = Data.define(:pid, :name, :argv)

    # Detection result for one pane: the agent (or nil) and its state.
    PaneAgentState = Data.define(:agent, :state)

    # Urgency weight for aggregating states; higher matters more.
    def self.state_priority(state)
      AGENT_STATES.index(state) || 0
    end

    # Lowercase the basename of a path or command and strip one known wrapper
    # extension, so `C:\bin\Claude.exe` compares as `claude`.
    def self.normalize_process_name(raw)
      basename = raw.split(%r{[/\\]}).last || raw
      name = basename.downcase
      STRIPPABLE_EXTENSIONS.each do |ext|
        if name.end_with?(ext)
          name = name.delete_suffix(ext)
          break
        end
      end
      name
    end

    # Match an already-normalized process name, including known aliases.
    def self.agent_from_name(name)
      AGENT_ALIASES[name]
    end

    # Identify an agent from a process name or path.
    def self.identify_agent(process_name)
      agent_from_name(normalize_process_name(process_name))
    end

    def self.generic_runtime?(name)
      GENERIC_RUNTIMES.include?(normalize_process_name(name))
    end

    def self.container_runtime?(name)
      CONTAINER_RUNTIMES.include?(normalize_process_name(name))
    end

    # True when a pane's foreground command is a container runtime, meaning the
    # agent runs inside a sandbox.
    def self.container_command?(command)
      container_runtime?(command)
    end

    # Find an agent invoked as a script argument to a generic runtime, e.g.
    # `node /path/to/codex`. An eval flag aborts detection because subsequent
    # arguments are inline code. Returns [agent, normalized_script_name] or nil.
    def self.identify_wrapped_agent(argv)
      return nil if argv.length < 2

      argv[1..].each do |arg|
        return nil if EVAL_FLAGS.include?(arg)
        next if arg.start_with?("-")

        normalized = normalize_process_name(arg)
        agent = agent_from_name(normalized)
        return [agent, normalized] if agent
      end
      nil
    end

    # Identify the agent running in a foreground job: direct match on the group
    # leader first, then any other process, then agents wrapped by a generic
    # runtime. Returns [agent, matched_name] or nil.
    def self.identify_agent_in_job(job)
      leader_pid = job.process_group_id
      match_leader(job, leader_pid) || match_other_process(job, leader_pid) || match_wrapped_process(job)
    end

    # Priority 1: direct match on the process group leader.
    def self.match_leader(job, leader_pid)
      leader = job.processes.find { |process| process.pid == leader_pid }
      return nil if leader.nil?

      agent = identify_agent(leader.name)
      agent ? [agent, leader.name] : nil
    end

    # Priority 2: direct match on any non-leader process.
    def self.match_other_process(job, leader_pid)
      job.processes.each do |process|
        next if process.pid == leader_pid

        agent = identify_agent(process.name)
        return [agent, process.name] if agent
      end
      nil
    end

    # Priority 3: an agent wrapped by a generic runtime on any process.
    def self.match_wrapped_process(job)
      job.processes.each do |process|
        next unless generic_runtime?(process.name) && process.argv

        result = identify_wrapped_agent(process.argv)
        return result if result
      end
      nil
    end

    # The pane to interact with for a window: the one running a known agent, or
    # the window's first pane when no agent is identified.
    def self.choose_agent_pane(panes, window)
      in_window = panes.select { |pane| pane.window_name == window }
      first = in_window.first
      return nil if first.nil?

      in_window.find { |pane| identify_agent(pane.pane_current_command) } || first
    end

    private_class_method :normalize_process_name, :agent_from_name, :generic_runtime?,
      :container_runtime?, :identify_wrapped_agent, :match_leader, :match_other_process,
      :match_wrapped_process
  end
end
