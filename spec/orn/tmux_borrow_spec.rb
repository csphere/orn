# frozen_string_literal: true

RSpec.describe Orn::Tmux do
  let(:output_mode) { Orn::OutputMode.default }

  describe ".join_pane" do
    it "joins the pane as a horizontal split with the given width" do
      with_fake_cmd do |fake|
        argv = ["tmux", "join-pane", "-h", "-s", "%5", "-t", "hub:tabs", "-l", "40%"]
        fake.script(argv)

        described_class.join_pane(
          output_mode,
          "%5",
          "hub:tabs",
          40,
          true
        )

        expect(fake.invocations).to eq([argv])
      end
    end

    it "detaches the join when focus is false" do
      with_fake_cmd do |fake|
        argv = ["tmux", "join-pane", "-h", "-d", "-s", "%5", "-t", "hub:tabs", "-l", "40%"]
        fake.script(argv)

        described_class.join_pane(
          output_mode,
          "%5",
          "hub:tabs",
          40,
          false
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe ".break_pane" do
    it "targets the session with a trailing colon" do
      with_fake_cmd do |fake|
        argv = ["tmux", "break-pane", "-d", "-s", "%5", "-n", "editor", "-t", "home:"]
        fake.script(argv)

        described_class.break_pane(
          output_mode,
          "%5",
          "home",
          "editor"
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end

  describe ".recreate_session_with_pane" do
    let(:cwd_argv) { ["tmux", "display-message", "-p", "-t", "%5", "\#{pane_current_path}"] }

    it "creates a placeholder session, moves the pane in, and kills the placeholder" do
      with_fake_cmd do |fake|
        new_session_argv = [
          "tmux",
          "new-session",
          "-d",
          "-s",
          "home",
          "-c",
          "/proj",
          "-P",
          "-F",
          "\#{window_id}"
        ]
        break_argv = ["tmux", "break-pane", "-d", "-s", "%5", "-n", "editor", "-t", "home:"]
        kill_argv = ["tmux", "kill-window", "-t", "@9"]
        fake.script(cwd_argv, stdout: "/proj\n")
        fake.script(new_session_argv, stdout: "@9\n")
        fake.script(break_argv)
        fake.script(kill_argv)

        described_class.recreate_session_with_pane(
          output_mode,
          "%5",
          "home",
          "editor"
        )

        expect(fake.invocations).to eq(
          [
            cwd_argv,
            new_session_argv,
            break_argv,
            kill_argv
          ]
        )
      end
    end

    it "raises when the pane's cwd cannot be determined" do
      with_fake_cmd do |fake|
        fake.script(cwd_argv, stdout: "\n")

        expect do
          described_class.recreate_session_with_pane(
            output_mode,
            "%5",
            "home",
            "editor"
          )
        end
          .to raise_error(Orn::Error, /cannot determine cwd/)
      end
    end
  end

  describe ".list_borrowed_panes" do
    let(:list_argv) do
      [
        "tmux",
        "list-panes",
        "-a",
        "-F",
        "\#{pane_id}\t\#{@orn_home_session}\t\#{@orn_home_window}"
      ]
    end

    it "returns only panes tagged with a home session and window" do
      with_fake_cmd do |fake|
        fake.script(list_argv, stdout: "%1\thome\teditor\n%2\t\t\n")

        panes = described_class.list_borrowed_panes(output_mode)

        expect(panes).to contain_exactly(
          Orn::Tmux::BorrowedPane.new(
            pane_id: "%1",
            home_session: "home",
            home_window: "editor"
          )
        )
      end
    end

    it "returns no panes when tmux fails" do
      with_fake_cmd do |fake|
        fake.script(
          list_argv,
          stderr: "no server running",
          status: 1
        )

        expect(described_class.list_borrowed_panes(output_mode)).to eq([])
      end
    end
  end

  describe ".active_pane" do
    let(:panes_argv) do
      [
        "tmux",
        "list-panes",
        "-t",
        "hub:tabs",
        "-F",
        "\#{pane_id}\t\#{?pane_active,1,0}"
      ]
    end

    it "returns the id of the active pane in the window" do
      with_fake_cmd do |fake|
        fake.script(panes_argv, stdout: "%1\t0\n%2\t1\n")

        pane = described_class.active_pane(
          output_mode,
          "hub",
          "tabs"
        )

        expect(pane).to eq("%2")
      end
    end

    it "returns nothing when the window does not exist" do
      with_fake_cmd do |fake|
        fake.script(
          panes_argv,
          stderr: "can't find window",
          status: 1
        )

        pane = described_class.active_pane(
          output_mode,
          "hub",
          "tabs"
        )

        expect(pane).to be_nil
      end
    end
  end

  describe ".current_session_window" do
    let(:display_argv) { ["tmux", "display-message", "-p", "-t", "%5", "\#{session_name}\t\#{window_name}"] }

    it "returns the session and window containing the pane" do
      with_fake_cmd do |fake|
        fake.script(display_argv, stdout: "home\teditor\n")

        expect(described_class.current_session_window(output_mode, "%5")).to eq(%w[home editor])
      end
    end

    it "returns nothing when the pane does not exist" do
      with_fake_cmd do |fake|
        fake.script(
          display_argv,
          stderr: "can't find pane",
          status: 1
        )

        expect(described_class.current_session_window(output_mode, "%5")).to be_nil
      end
    end
  end

  describe ".bind_key_guarded" do
    it "binds through if-shell with a send-keys fallthrough" do
      with_fake_cmd do |fake|
        condition = described_class.window_guard_condition("hub", "tabs")
        argv = [
          "tmux",
          "bind-key",
          "-n",
          "F1",
          "if-shell",
          "-F",
          condition,
          "select-window -t hub:tabs",
          "send-keys F1"
        ]
        fake.script(argv)

        described_class.bind_key_guarded(
          output_mode,
          "F1",
          condition,
          "select-window -t hub:tabs"
        )

        expect(fake.invocations).to eq([argv])
      end
    end
  end
end
