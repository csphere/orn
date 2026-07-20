# frozen_string_literal: true

module Orn
  module TUI
    # Finds bare-worktree projects across the configured scan roots and builds
    # the RepoEntry list for the global tree: display names (disambiguated on
    # collision), worktree rows, persisted MRU/expanded state applied, and the
    # tiered sort order. Live tmux fields (session, agent state) are filled in
    # later by the app's tmux refresh.
    module RepoDiscovery
      # Scan every root, apply the persisted MRU and expanded state, and prune
      # persisted state for repos no longer found. Returns entries ready for
      # the tmux refresh and sort.
      def self.discover(output, config, state)
        repos = []
        config.scan_roots.each do |root|
          scan_root(
            root,
            config.scan_depth,
            output,
            repos
          )
        end
        repos = disambiguate_names(config.scan_roots, repos)
        repos = apply_mru(state, repos)
        repos = apply_expanded(state, repos)
        prune_mru(state, repos)
        repos
      end

      # Find `.bare` directories under `root` (via `find`, up to `depth`) and
      # append a RepoEntry for each containing project.
      def self.scan_root(root, depth, output, repos)
        result = Orn::Cmd.new(output_mode: output)
          .output("find", root.to_s, "-maxdepth", depth.to_s, "-name", ".bare", "-type", "d")
        return unless result.success?

        result.stdout.lines.each do |line|
          bare_path = line.strip
          next if bare_path.empty?

          repos << repo_entry_for(bare_path, root, output)
        end
      rescue Orn::Error
        nil
      end

      def self.repo_entry_for(bare_path, scan_root, output)
        project_root = File.dirname(bare_path)
        config = Orn::Config.load(project_root)
        agent = config.sbx&.agent_type && Orn::Detect.identify_agent(config.sbx.agent_type)
        project = Orn::Git::Project.new(
          root: project_root,
          config: config
        )
        RepoEntry.new(
          display_name: relative_display_name(project_root, scan_root),
          root: project_root,
          healthy: healthy?(project_root),
          session_name: Orn::Session.session_name(project),
          base_branch: config.base,
          worktrees: list_worktree_rows(output, project_root, config.base),
          sbx_agent_type: agent
        )
      end

      # `project_root` relative to `scan_root` when nested under it, else the
      # absolute path.
      def self.relative_display_name(project_root, scan_root)
        prefix = "#{scan_root.to_s.chomp("/")}/"
        project_root.start_with?(prefix) ? project_root[prefix.length..] : project_root
      end

      # Worktree rows for a repo, base branch first, then alphabetical.
      def self.list_worktree_rows(output, root, base)
        branches = Orn::Git::Worktree.new(
          root: root,
          output_mode: output
        ).branches
        sort_branches_base_first(branches, base)
        branches.map { |branch| WorktreeRow.new(branch: branch) }
      end

      def self.sort_branches_base_first(branches, base)
        branches.sort_by! { |branch| [branch == base ? 0 : 1, branch] }
      end

      # A project is healthy when `.bare/HEAD` exists and is readable.
      def self.healthy?(project_root)
        head = File.join(project_root, ".bare", "HEAD")
        File.file?(head) && File.readable?(head)
      end

      def self.apply_mru(state, repos)
        repos.map { |repo| repo.with(mru_timestamp: state.timestamp(repo.root)) }
      end

      def self.apply_expanded(state, repos)
        repos.map { |repo| repo.with(expanded: state.expanded?(repo.root)) }
      end

      # Drop persisted state for repos no longer discovered, and save.
      def self.prune_mru(state, repos)
        state.prune(repos.map(&:root))
        state.save
      end

      # Order repos by tier: live sessions by activity (newest first), then
      # previously entered repos by MRU timestamp, then the rest alphabetically.
      def self.sort_entries(repos)
        repos.sort! do |a, b|
          tier_a = sort_tier(a)
          tier_b = sort_tier(b)
          next tier_a <=> tier_b unless tier_a == tier_b

          tier_order(tier_a, a, b)
        end
      end

      def self.tier_order(tier, first, second)
        case tier
        when 0 then (second.session_activity || 0) <=> (first.session_activity || 0)
        when 1 then (second.mru_timestamp || "") <=> (first.mru_timestamp || "")
        else first.display_name <=> second.display_name
        end
      end

      # 0 = live session, 1 = previously entered (MRU), 2 = unseen.
      def self.sort_tier(entry)
        return 0 if entry.session_alive
        return 1 if entry.mru_timestamp

        2
      end

      # Prefix colliding display names with their scan root's basename.
      # Returns the (possibly renamed) entries.
      def self.disambiguate_names(scan_roots, repos)
        return repos if scan_roots.length <= 1

        needs_prefix = collisions(repos)
        repos.each_with_index.map do |repo, i|
          next repo unless needs_prefix[i]

          root = scan_roots.find { |candidate| repo.root.to_s.start_with?(candidate.to_s) }
          next repo unless root

          repo.with(display_name: "#{File.basename(root.to_s)}/#{repo.display_name}")
        end
      end

      def self.collisions(repos)
        needs = Array.new(repos.length, false)
        repos.each_index do |i|
          ((i + 1)...repos.length).each do |j|
            next unless repos[i].display_name == repos[j].display_name

            needs[i] = true
            needs[j] = true
          end
        end
        needs
      end
    end
  end
end
