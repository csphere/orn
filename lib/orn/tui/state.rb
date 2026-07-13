# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Orn
  module TUI
    # Persisted TUI state, keyed by repo root path: per-repo MRU timestamps and
    # which repos are expanded in the global tree. Stored as JSON under XDG
    # state. A nil path makes `save` a no-op, so tests never touch the real
    # state file.
    class State
      attr_reader :mru, :expanded

      def initialize(mru: {}, expanded: [], path: nil)
        @mru = mru
        @expanded = expanded
        @path = path
      end

      # Load from the XDG state file, remembering the path so `save` writes back.
      def self.load
        path = state_path
        state = load_from(path)
        state.instance_variable_set(:@path, path)
        state
      end

      def self.load_from(path)
        raw = JSON.parse(File.read(path))
        new(mru: hash_or_empty(raw["mru"]), expanded: array_or_empty(raw["expanded"]))
      rescue SystemCallError, JSON::ParserError
        new
      end

      def save
        save_to(@path) if @path
      end

      def save_to(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(to_h))
      rescue SystemCallError
        nil
      end

      # Record `root` as entered now.
      def touch(root)
        @mru[root.to_s] = self.class.timestamp_now
      end

      # The MRU timestamp recorded by `touch`, if any.
      def timestamp(root)
        @mru[root.to_s]
      end

      # Drop MRU and expanded entries for roots no longer discovered.
      def prune(existing_roots)
        roots = existing_roots.map(&:to_s)
        @mru.select! { |path, _| roots.include?(path) }
        @expanded.select! { |path| roots.include?(path) }
      end

      def expanded?(root)
        @expanded.include?(root.to_s)
      end

      def set_expanded(root, expanded)
        key = root.to_s
        if expanded
          @expanded << key unless @expanded.include?(key)
        else
          @expanded.delete(key)
        end
      end

      # Serialized shape (mru then expanded, contents sorted for stable,
      # comparable output).
      def to_h
        { "mru" => @mru.sort.to_h, "expanded" => @expanded.sort }
      end

      # `$XDG_STATE_HOME/orn/tui.json`, falling back to /tmp when no home dir
      # resolves.
      def self.state_path
        base = Orn::Fs.xdg_dir("XDG_STATE_HOME", ".local/state")
        base ? File.join(base, "orn", "tui.json") : "/tmp/orn-tui-state.json"
      end

      def self.timestamp_now
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      def self.hash_or_empty(value)
        value.is_a?(Hash) ? value : {}
      end

      def self.array_or_empty(value)
        value.is_a?(Array) ? value : []
      end

      private_class_method :hash_or_empty, :array_or_empty
    end
  end
end
