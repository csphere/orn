# frozen_string_literal: true

require "digest"
require "fileutils"

module Orn
  # Trust approval for commands defined in project config: tmux pane commands
  # and sbx lifecycle commands. Approvals are content fingerprints stored per
  # project under the XDG data dir, so any change to the commands requires
  # re-approval. Global and default config is implicitly trusted.
  #
  # Fingerprints use SHA256 (64 hex chars). The store is orn-namespaced and read
  # by nothing else, so the framing only has to be internally consistent.
  module Trust # rubocop:disable Metrics/ModuleLength
    # Format version prefix in approval files; bumping it invalidates every
    # stored approval.
    APPROVAL_VERSION = "v1"

    # Gates project-defined pane commands behind user approval. Approved layouts
    # pass through unchanged; declining strips the commands; unapproved commands
    # in a non-interactive session are an error.
    def self.check_trust(output_mode, project_root, layout, source)
      data_dir = approval_data_dir
      raise Orn::Error, "Could not determine data directory for pane command approval" if data_dir.nil?

      check_trust_with(output_mode, project_root, layout, source, data_dir)
    end

    # Like check_trust, but never prompts: untrusted project pane commands fail
    # instead. For callers that own the terminal (the TUI), where a prompt would
    # garble the screen.
    def self.check_trust_non_interactive(output_mode, project_root, layout, source)
      data_dir = approval_data_dir
      raise Orn::Error, "Could not determine data directory for pane command approval" if data_dir.nil?

      check_trust_inner(output_mode, project_root, layout, source, data_dir, interactive: false)
    end

    def self.check_trust_with(output_mode, project_root, layout, source, data_dir)
      check_trust_inner(output_mode, project_root, layout, source, data_dir, interactive: interactive?)
    end

    def self.check_trust_inner(output_mode, project_root, layout, source, data_dir, interactive:)
      return layout unless source == :project

      commands = extract_commands(layout)
      return layout if commands.empty?

      approved = check_trust_flow(
        commands_fingerprint(commands), approval_path(data_dir, project_root), commands,
        header: "Project config contains pane commands that will be executed:",
        prompt: "Trust these commands? [y/N] ",
        non_interactive_msg: "Project config contains untrusted pane commands\n  " \
                             "Run 'orn open <branch>' interactively to review and approve them",
        interactive: interactive
      )
      return layout if approved

      output_mode.status("Skipping pane commands (not approved)")
      strip_commands(layout)
    end

    # Non-empty pane commands in layout order; empty panes are plain shells and
    # need no approval.
    def self.extract_commands(layout)
      commands = []
      for_each_pane(layout) { |pane| commands << pane unless pane.empty? }
      commands
    end

    # The same layout shape with every pane command cleared to a plain shell.
    def self.strip_commands(layout)
      map_panes(layout) { |_| "" }
    end

    # SHA256 hex digest over the command count and 0xff-delimited commands;
    # sensitive to content, order, and boundaries between commands.
    def self.commands_fingerprint(commands)
      digest = Digest::SHA256.new
      hash_list(digest, commands)
      digest.hexdigest
    end

    # SHA256 hex digest of the project root path; names the per-project approval
    # file.
    def self.project_id(project_root)
      Digest::SHA256.hexdigest(project_root.to_s)
    end

    def self.approval_path(data_dir, project_root)
      File.join(data_dir, project_id(project_root))
    end

    # True when the approval file holds exactly `<APPROVAL_VERSION>:<hash>`
    # matching `fingerprint`. Missing files, older formats, and mismatched
    # hashes all count as unapproved.
    def self.approved?(path, fingerprint)
      prefix = "#{APPROVAL_VERSION}:"
      stored = File.read(path).strip
      return false unless stored.start_with?(prefix)

      stored.delete_prefix(prefix) == fingerprint
    rescue SystemCallError
      false
    end

    # Writes `<APPROVAL_VERSION>:<fingerprint>` with owner-only permissions
    # (0700 directory, 0600 file).
    def self.save_approval(path, fingerprint)
      parent = File.dirname(path)
      FileUtils.mkdir_p(parent)
      File.chmod(0o700, parent)
      File.write(path, "#{APPROVAL_VERSION}:#{fingerprint}\n")
      File.chmod(0o600, path)
      nil
    end

    # --- Sandbox command trust ---

    # Gates sbx setup and start commands, build args, and env vars behind user
    # approval. Unlike pane commands there is no degrade path: declining or
    # running unapproved non-interactively is an error.
    def self.check_sbx_trust(project_root, sbx)
      data_dir = approval_data_dir
      raise Orn::Error, "Could not determine data directory for sandbox command approval" if data_dir.nil?

      check_sbx_trust_with(project_root, sbx, data_dir)
    end

    def self.check_sbx_trust_with(project_root, sbx, data_dir)
      check_sbx_trust_inner(project_root, sbx, data_dir, interactive?)
    end

    def self.check_sbx_trust_inner(project_root, sbx, data_dir, interactive)
      return unless sbx_commands?(sbx)

      items = format_sbx_items(sbx)
      non_interactive_msg = "Project config contains untrusted sandbox commands:\n  " \
                            "#{items.join("\n  ")}\n  Run interactively to review and approve them"
      approved = check_trust_flow(
        sbx_fingerprint(sbx), sbx_approval_path(data_dir, project_root), items,
        header: "The sbx config will run these commands:",
        prompt: "Approve? [y/N] ",
        non_interactive_msg: non_interactive_msg,
        interactive: interactive
      )
      raise Orn::Error, "Sandbox commands not approved" unless approved

      nil
    end

    # Whether the sbx config contains anything that needs approval.
    def self.sbx_commands?(sbx)
      !sbx.setup.empty? ||
        !sbx.start.nil? ||
        (!sbx.build.nil? && !sbx.build.build_args.empty?) ||
        !sbx.env.empty?
    end

    # SHA256 hex digest over the trust-relevant sbx fields, each prefixed with
    # a domain label so values cannot shift between fields undetected.
    def self.sbx_fingerprint(sbx)
      digest = Digest::SHA256.new
      hash_sbx_setup(digest, sbx.setup)
      hash_sbx_start(digest, sbx.start)
      hash_sbx_build_args(digest, sbx.build)
      hash_sbx_env(digest, sbx.env)
      digest.hexdigest
    end

    # Human-readable lines for the approval prompt, one per trust-relevant
    # value, tagged with the field it came from.
    def self.format_sbx_items(sbx)
      items = []
      format_sbx_setup(items, sbx.setup)
      items << "[start]     #{sbx.start}" unless sbx.start.nil?
      sbx.build&.build_args&.each { |arg| items << "[build arg] reads #{arg} from environment" }
      sbx.env.each { |key, value| items << "[env]       #{key} = #{value}" }
      items
    end

    def self.interactive?
      $stdin.tty?
    end

    # Shared approval flow: true when the fingerprint is already approved or the
    # user confirms (persisting the approval), false when the user declines,
    # raises when unapproved and non-interactive.
    def self.check_trust_flow(fingerprint, path, display_items, header:, prompt:, non_interactive_msg:, interactive:)
      return true if approved?(path, fingerprint)
      raise Orn::Error, non_interactive_msg unless interactive

      confirmed = Orn::Confirm.with_stdin_stderr do |reader, writer|
        confirm_prompt(display_items, header: header, prompt: prompt, reader: reader, writer: writer)
      end
      return false unless confirmed

      save_approval(path, fingerprint)
      true
    end

    # Prints the header and a numbered list of items, then reads a yes/no answer
    # (default no).
    def self.confirm_prompt(items, header:, prompt:, reader:, writer:)
      writer.puts header
      items.each_with_index { |item, index| writer.puts "  #{index + 1}. #{item}" }
      writer.print prompt
      writer.flush
      Orn::Confirm.read_yes_no(reader)
    end

    # Approval storage directory: $XDG_DATA_HOME/orn/approved, falling back to
    # ~/.local/share/orn/approved. nil when neither is available.
    def self.approval_data_dir
      base = Orn::Fs.xdg_dir("XDG_DATA_HOME", ".local/share")
      base.nil? ? nil : File.join(base, "orn", "approved")
    end

    # Like approval_path, but with an sbx- prefix so sandbox and pane approvals
    # are stored independently.
    def self.sbx_approval_path(data_dir, project_root)
      File.join(data_dir, "sbx-#{project_id(project_root)}")
    end

    # Rebuilds a layout with `transform` applied to every pane command.
    def self.map_panes(layout, &transform)
      return Config::Layout.of_columns(map_columns(layout.columns, &transform)) if layout.columns?

      rows = layout.rows.map do |row|
        next Config::Row.new(panes: [], columns: map_columns(row.columns, &transform)) if row.columns?

        Config::Row.new(panes: row.panes.map(&transform), columns: [])
      end
      Config::Layout.of_rows(rows)
    end

    def self.map_columns(columns, &transform)
      columns.map { |column| Config::Column.new(panes: column.panes.map(&transform)) }
    end

    # Visits every pane command in layout order.
    def self.for_each_pane(layout, &block)
      return each_column_pane(layout.columns, &block) if layout.columns?

      layout.rows.each do |row|
        next each_column_pane(row.columns, &block) if row.columns?

        row.panes.each(&block)
      end
    end

    def self.each_column_pane(columns, &block)
      columns.each { |column| column.panes.each(&block) }
    end

    # Hashes a count-prefixed, 0xff-delimited list of strings. Shared by every
    # fingerprint so count, order, and boundaries always matter.
    def self.hash_list(digest, items)
      digest.update([items.length].pack("Q<"))
      items.each do |item|
        digest.update(item.b)
        digest.update("\xff".b)
      end
    end

    def self.hash_sbx_setup(digest, setup)
      return if setup.empty?

      digest.update("setup\xff".b)
      hash_list(digest, setup)
    end

    def self.hash_sbx_start(digest, start)
      return if start.nil?

      digest.update("start\xff".b)
      digest.update(start.b)
      digest.update("\xff".b)
    end

    def self.hash_sbx_build_args(digest, build)
      return if build.nil?

      digest.update("build_args\xff".b)
      hash_list(digest, build.build_args)
    end

    def self.hash_sbx_env(digest, env)
      return if env.empty?

      digest.update("env\xff".b)
      digest.update([env.length].pack("Q<"))
      env.each do |key, value|
        digest.update(key.b)
        digest.update("\xff".b)
        digest.update(value.b)
        digest.update("\xff".b)
      end
    end

    def self.format_sbx_setup(items, setup)
      if setup.length == 1
        items << "[setup]     #{setup[0]}"
        return
      end

      setup.each_with_index { |command, index| items << "[setup #{index + 1}/#{setup.length}] #{command}" }
    end

    private_class_method :interactive?, :check_trust_flow, :approval_data_dir,
      :sbx_approval_path, :map_panes, :map_columns, :for_each_pane, :each_column_pane,
      :hash_list, :hash_sbx_setup, :hash_sbx_start, :hash_sbx_build_args, :hash_sbx_env,
      :format_sbx_setup
  end
end
