# frozen_string_literal: true

require "tmpdir"

RSpec.describe Orn::Cmd, :real_cmd do
  subject(:cmd) { described_class.new(output_mode: Orn::OutputMode.default) }

  describe "#run" do
    context "when the command succeeds" do
      it "returns the captured output" do
        result = cmd.run("echo", "hello")

        expect(result).to be_success
        expect(result.stdout.strip).to eq("hello")
      end
    end

    context "when the command exits nonzero" do
      it "raises with the stderr text" do
        expect do
          cmd.run(
            "sh",
            "-c",
            "echo bad >&2; exit 1"
          )
        end
          .to raise_error(Orn::Error, /bad/)
      end

      it "names the program when stderr is empty" do
        expect do
          cmd.run(
            "sh",
            "-c",
            "exit 1"
          )
        end
          .to raise_error(Orn::Error, /sh/)
      end

      it "reports the exit code when stderr is empty" do
        expect do
          cmd.run(
            "sh",
            "-c",
            "exit 42"
          )
        end
          .to raise_error(Orn::Error, /42/)
      end
    end

    context "when the program does not exist" do
      it "raises naming the missing program" do
        expect { cmd.run("nonexistent-binary-xyz") }
          .to raise_error(Orn::Error, /nonexistent-binary-xyz/)
      end
    end
  end

  describe "#exec" do
    context "when the command succeeds" do
      it "returns nil" do
        expect(cmd.exec("true")).to be_nil
      end
    end

    context "when the command fails" do
      it "raises with the stderr text" do
        expect do
          cmd.exec(
            "sh",
            "-c",
            "echo oops >&2; exit 1"
          )
        end
          .to raise_error(Orn::Error, /oops/)
      end
    end
  end

  describe "#output" do
    context "when the command exits nonzero" do
      it "returns the result instead of raising" do
        result = cmd.output("sh", "-c", "exit 3")

        expect(result).not_to be_success
        expect(result.status).to eq(3)
      end
    end
  end

  describe "chdir" do
    it "runs the command in the given directory" do
      dir = register_temp_dir(Dir.mktmpdir("orn-cmd-chdir"))
      chdir_cmd = described_class.new(
        output_mode: Orn::OutputMode.default,
        chdir: dir
      )

      result = chdir_cmd.run("pwd")

      expect(result.stdout.strip).to eq(File.realpath(dir))
    end
  end

  describe "verbose logging" do
    subject(:verbose_cmd) do
      described_class.new(
        output_mode: Orn::OutputMode.new(
          verbose: true,
          json: false
        )
      )
    end

    context "when the command succeeds" do
      it "logs the invocation and an ok line with the exit code" do
        expect { verbose_cmd.output("echo", "hello") }
          .to output("[cmd] echo hello\n[ok]  exit 0\n").to_stderr
      end
    end

    context "when the command exits nonzero" do
      it "logs each stderr line and the exit code as error lines" do
        script = "echo first >&2; echo second >&2; exit 3"

        expect { verbose_cmd.output("sh", "-c", script) }
          .to output(
            "[cmd] sh -c #{script}\n" \
              "[err] first\n" \
              "[err] second\n" \
              "[err] exit 3\n"
          ).to_stderr
      end
    end

    context "when the mode is not verbose" do
      it "logs nothing" do
        expect { cmd.output("sh", "-c", "echo noise >&2; exit 1") }
          .not_to output.to_stderr
      end
    end

    context "when arguments carry secret values" do
      it "masks the value of a --build-arg pair but passes it through unmasked" do
        result = nil

        expect { result = verbose_cmd.output("echo", "--build-arg", "TOKEN=hunter2") }
          .to output(a_string_including("[cmd] echo --build-arg TOKEN=***")).to_stderr
        expect(result.stdout).to include("TOKEN=hunter2")
      end

      it "leaves a --build-arg value without an equals sign unmasked" do
        expect { verbose_cmd.output("echo", "--build-arg", "TOKEN") }
          .to output(a_string_including("[cmd] echo --build-arg TOKEN\n")).to_stderr
      end

      it "masks every KEY=VALUE entry after an env token" do
        arguments = %w[env API_KEY=secret DB_PASS=hunter2 sh]

        expect { verbose_cmd.output("echo", *arguments) }
          .to output(a_string_including("[cmd] echo env API_KEY=*** DB_PASS=*** sh")).to_stderr
      end

      it "stops masking once the env prefix ends" do
        arguments = %w[env KEY=secret sh -c name=value]

        expect { verbose_cmd.output("echo", *arguments) }
          .to output(a_string_including("[cmd] echo env KEY=*** sh -c name=value")).to_stderr
      end

      it "leaves ordinary KEY=VALUE arguments alone" do
        expect { verbose_cmd.output("echo", "name=value") }
          .to output(a_string_including("[cmd] echo name=value")).to_stderr
      end
    end
  end
end
