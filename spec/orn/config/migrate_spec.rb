# frozen_string_literal: true

require "yaml"
require "tmpdir"
require "fileutils"

RSpec.describe Orn::Config::Migrate do
  let(:binary) { described_class.binary_version }

  describe ".check_version" do
    let(:seven) { Gem::Version.new("0.7.0") }

    it "reports a match" do
      expect(described_class.check_version("0.7.0", seven).kind).to eq(:match)
    end

    it "reports behind on an older minor" do
      expect(described_class.check_version("0.6.0", seven).kind).to eq(:behind)
    end

    it "reports behind on an older patch" do
      expect(described_class.check_version("0.7.0", Gem::Version.new("0.7.1")).kind).to eq(:behind)
    end

    it "reports ahead on a newer version" do
      expect(described_class.check_version("0.8.0", seven).kind).to eq(:ahead)
    end

    it "reports missing when absent" do
      expect(described_class.check_version(nil, seven).kind).to eq(:missing)
    end

    it "treats an unparsable version as missing" do
      expect(described_class.check_version("not-a-version", seven).kind).to eq(:missing)
    end
  end

  describe ".enforce_version" do
    let(:seven) { Gem::Version.new("0.7.0") }

    it "passes when current" do
      expect { described_class.enforce_version("0.7.0", "test.yaml", seven) }.not_to raise_error
    end

    it "halts when behind, pointing at the migrate command" do
      expect { described_class.enforce_version("0.6.0", "test.yaml", seven) }
        .to raise_error(Orn::Error, /behind.*orn config migrate/m)
    end

    it "passes when ahead" do
      expect { described_class.enforce_version("0.8.0", "test.yaml", seven) }.not_to raise_error
    end

    it "passes when missing" do
      expect { described_class.enforce_version(nil, "test.yaml", seven) }.not_to raise_error
    end
  end

  describe ".next_backup_path / .backup" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "config.yaml") }

    before { File.write(path, "original content") }

    after { FileUtils.remove_entry(dir, true) }

    it "picks .bak.1 first" do
      expect(described_class.next_backup_path(path)).to eq("#{path}.bak.1")
    end

    it "increments past existing backups" do
      File.write("#{path}.bak.1", "old1")
      File.write("#{path}.bak.2", "old2")

      expect(described_class.next_backup_path(path)).to eq("#{path}.bak.3")
    end

    it "copies the file contents into the backup" do
      backup_path = described_class.backup(path)

      aggregate_failures do
        expect(File.read(backup_path)).to eq("original content")
        expect(File).to exist(path)
      end
    end
  end

  describe ".binary_version" do
    it "is a released Gem::Version" do
      expect(binary).to be > Gem::Version.new("0")
    end
  end

  describe ".plan" do
    it "is empty when the config already matches the binary" do
      table = YAML.safe_load("orn_version: \"#{Orn::VERSION}\"\ngit:\n  base: main\n")

      expect(described_class.plan(table, Orn::VERSION).descriptions).to be_empty
    end

    it "adds an orn_version entry when the version is missing" do
      table = YAML.safe_load("git:\n  base: main\n")

      expect(described_class.plan(table, nil).descriptions).to include(a_string_including("orn_version"))
    end

    it "detects a legacy top-level base key" do
      expect(described_class.plan(YAML.safe_load("base: main\n"), nil).descriptions)
        .to include(a_string_including("base"))
    end

    it "detects a legacy symlinks.worktree key" do
      table = YAML.safe_load("symlinks:\n  worktree:\n    - .env\n")

      expect(described_class.plan(table, nil).descriptions).to include(a_string_including("worktree"))
    end

    it "plans only the version bump for a clean sectioned config" do
      descriptions = described_class.plan(YAML.safe_load("git:\n  base: main\n"), nil).descriptions

      expect(descriptions).to contain_exactly(a_string_including("orn_version"))
    end
  end

  describe ".apply" do
    it "moves a top-level base into the git section" do
      table = YAML.safe_load("base: develop\n")

      described_class.apply(table, nil)

      aggregate_failures do
        expect(table).not_to have_key("base")
        expect(table.dig("git", "base")).to eq("develop")
      end
    end

    it "moves a top-level session into the tmux section" do
      table = YAML.safe_load("session: work\n")

      described_class.apply(table, nil)

      expect(table.dig("tmux", "session")).to eq("work")
    end

    it "moves top-level columns and rows into the tmux section" do
      columns = YAML.safe_load("columns:\n  - panes: [vim]\n")
      rows = YAML.safe_load("rows:\n  - panes: [top]\n")

      described_class.apply(columns, nil)
      described_class.apply(rows, nil)

      aggregate_failures do
        expect(columns["tmux"]).to have_key("columns")
        expect(rows["tmux"]).to have_key("rows")
      end
    end

    it "renames symlinks.worktree to symlinks.base" do
      table = YAML.safe_load("symlinks:\n  worktree:\n    - .env\n")

      described_class.apply(table, nil)

      aggregate_failures do
        expect(table["symlinks"]).not_to have_key("worktree")
        expect(table["symlinks"]).to have_key("base")
      end
    end

    it "stamps the binary version" do
      table = YAML.safe_load("git:\n  base: main\n")

      described_class.apply(table, nil)

      expect(table["orn_version"]).to eq(binary.to_s)
    end

    it "never overwrites an existing section key" do
      table = YAML.safe_load("base: develop\ngit:\n  base: main\n")

      described_class.apply(table, nil)

      aggregate_failures do
        expect(table).not_to have_key("base")
        expect(table.dig("git", "base")).to eq("main")
      end
    end

    it "is idempotent" do
      table = YAML.safe_load("base: main\n")
      described_class.apply(table, nil)
      snapshot = Marshal.load(Marshal.dump(table))

      described_class.apply(table, binary.to_s)

      expect(table).to eq(snapshot)
    end

    it "does nothing when the version already matches the binary" do
      table = YAML.safe_load("orn_version: \"#{Orn::VERSION}\"\ngit:\n  base: main\n")
      before = Marshal.load(Marshal.dump(table))

      described_class.apply(table, Orn::VERSION)

      expect(table).to eq(before)
    end
  end

  describe ".add_version_line" do
    it "prepends a version line to a clean config" do
      result = described_class.add_version_line("git:\n  base: main\n", binary)

      aggregate_failures do
        expect(result).to start_with("orn_version:")
        expect(result).to include("git:\n  base: main")
      end
    end

    it "replaces an existing version line" do
      result = described_class.add_version_line("orn_version: \"0.0.5\"\ngit:\n  base: main\n", binary)

      aggregate_failures do
        expect(result).to include("orn_version: \"#{binary}\"")
        expect(result).not_to include("0.0.5")
      end
    end

    it "preserves leading comments" do
      result = described_class.add_version_line("# My config\n\ngit:\n  base: main\n", binary)

      aggregate_failures do
        expect(result).to start_with("orn_version:")
        expect(result).to include("# My config")
      end
    end
  end

  describe ".migrate_file" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "config.yaml") }

    after { FileUtils.remove_entry(dir, true) }

    it "adds a version to an unversioned config and backs it up" do
      File.write(path, "git:\n  base: main\n")

      result = described_class.migrate_file(path, dry_run: false)

      aggregate_failures do
        expect(result.up_to_date).to be(false)
        expect(result.backup_path).not_to be_nil
        expect(File.read(path)).to include("orn_version", "git:")
      end
    end

    it "moves legacy keys into sections" do
      File.write(path, "base: develop\nsession: work\n")

      described_class.migrate_file(path, dry_run: false)

      expect(File.read(path)).to include("git:", "tmux:", "orn_version")
    end

    it "creates a backup with the original contents" do
      original = "git:\n  base: main\n"
      File.write(path, original)

      result = described_class.migrate_file(path, dry_run: false)

      expect(File.read(result.backup_path)).to eq(original)
    end

    it "writes nothing on a dry run" do
      original = "git:\n  base: main\n"
      File.write(path, original)

      result = described_class.migrate_file(path, dry_run: true)

      aggregate_failures do
        expect(result.up_to_date).to be(false)
        expect(result.backup_path).to be_nil
        expect(File.read(path)).to eq(original)
      end
    end

    it "reports an up-to-date config with no changes" do
      File.write(path, "orn_version: \"#{Orn::VERSION}\"\ngit:\n  base: main\n")

      result = described_class.migrate_file(path, dry_run: false)

      aggregate_failures do
        expect(result.up_to_date).to be(true)
        expect(result.changes).to be_empty
      end
    end

    it "preserves comments for a version-only migration" do
      File.write(path, "git:\n  # Base branch for new worktrees.\n  base: main\n")

      described_class.migrate_file(path, dry_run: false)

      expect(File.read(path)).to include("# Base branch for new worktrees.")
    end
  end

  describe ".enforce_file_version" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "config.yaml") }

    after { FileUtils.remove_entry(dir, true) }

    it "passes for a current config" do
      File.write(path, "orn_version: \"#{Orn::VERSION}\"\ngit:\n  base: main\n")

      expect { described_class.enforce_file_version(path, binary) }.not_to raise_error
    end

    it "passes for a missing file" do
      expect { described_class.enforce_file_version(File.join(dir, "missing.yaml"), binary) }.not_to raise_error
    end

    it "passes for a clean unversioned config" do
      File.write(path, "git:\n  base: main\n")

      expect { described_class.enforce_file_version(path, binary) }.not_to raise_error
    end

    it "catches a legacy top-level base key" do
      File.write(path, "base: main\n")

      expect { described_class.enforce_file_version(path, binary) }
        .to raise_error(Orn::Error, /base.*orn config migrate/m)
    end

    it "catches a legacy symlinks.worktree key" do
      File.write(path, "symlinks:\n  worktree:\n    - .env\n")

      expect { described_class.enforce_file_version(path, binary) }.to raise_error(Orn::Error, /worktree/)
    end
  end
end
