# frozen_string_literal: true

RSpec.describe FakeCmdBackend do
  let(:cmd) { Orn::Cmd.new(output_mode: Orn::OutputMode.default) }

  it "returns the scripted result through Orn::Cmd" do
    with_fake_cmd do |fake|
      fake.script(
        %w[git status],
        stdout: "clean"
      )

      result = cmd.output("git", "status")

      expect(result.stdout).to eq("clean")
      expect(result).to be_success
    end
  end

  it "records every invocation" do
    with_fake_cmd do |fake|
      fake.script(%w[git fetch])
      cmd.output("git", "fetch")
      cmd.output("git", "fetch")

      expect(fake.invocations).to eq(
        [
          %w[git fetch],
          %w[git fetch]
        ]
      )
    end
  end

  it "raises on an unscripted invocation" do
    with_fake_cmd do
      expect { cmd.output("git", "status") }
        .to raise_error(FakeCmdBackend::UnscriptedCommand, /git status/)
    end
  end

  it "feeds Cmd's command-not-found error path" do
    with_fake_cmd do |fake|
      fake.script_missing(%w[figd status])

      expect { cmd.output("figd", "status") }
        .to raise_error(Orn::Error, /Failed to run figd: command not found/)
    end
  end

  it "feeds Cmd#run's nonzero-exit error path" do
    with_fake_cmd do |fake|
      fake.script(
        %w[git push],
        stderr: "rejected",
        status: 1
      )

      expect { cmd.run("git", "push") }.to raise_error(Orn::Error, /rejected/)
    end
  end

  it "restores the real backend after the block" do
    original_backend = Orn::Cmd.backend

    with_fake_cmd { nil }

    expect(Orn::Cmd.backend).to be(original_backend)
  end

  it "restores the real backend when the block raises" do
    original_backend = Orn::Cmd.backend

    expect { with_fake_cmd { raise "boom" } }.to raise_error("boom")
    expect(Orn::Cmd.backend).to be(original_backend)
  end
end
