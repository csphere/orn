# frozen_string_literal: true

RSpec.describe FakeTmuxClient do
  let(:fake) { described_class.new }

  it "records effect calls in order at domain level" do
    fake.set_pane_option(
      "%5",
      "@orn_home_session",
      "repo"
    )
    fake.join_pane(
      "%5",
      "%0",
      67,
      true
    )

    expect(fake.calls).to eq(
      [
        [:set_pane_option, "%5", "@orn_home_session", "repo"],
        [:join_pane, "%5", "%0", 67, true]
      ]
    )
  end

  it "raises after recording when the verb is in fail_on" do
    failing = described_class.new(fail_on: [:join_pane])

    expect do
      failing.join_pane(
        "%5",
        "%0",
        67,
        true
      )
    end.to raise_error(Orn::Error, /join_pane failed/)
    expect(failing.count(:join_pane)).to eq(1)
  end

  it "backs window queries with settable state" do
    fake.windows = { "repo" => %w[main feat] }
    fake.sessions = ["repo"]

    aggregate_failures do
      expect(fake.window_exists?("repo", "feat")).to be(true)
      expect(fake.window_exists?("repo", "gone")).to be(false)
      expect(fake.list_windows("repo")).to eq(%w[main feat])
      expect(fake.list_windows("absent")).to eq([])
      expect(fake.session_exists?("repo")).to be(true)
      expect(fake.session_exists?("absent")).to be(false)
    end
  end

  it "defaults the all-panes listing to empty but keeps nil settable" do
    expect(fake.list_all_panes_metadata).to eq([])

    fake.all_panes = nil

    expect(fake.list_all_panes_metadata).to be_nil
  end

  it "mints an open result and records the branch window as existing" do
    project = make_project(make_bare_project)
    session = Orn::Session.session_name(project)

    result = fake.open_window_non_interactive(project, "feat")

    aggregate_failures do
      expect(result).to eq(
        Orn::Tmux::OpenWindowResult.new(
          branch: "feat",
          session: session
        )
      )
      expect(fake.window_exists?(session, "feat")).to be(true)
      expect(fake.calls.first).to eq([:open_window_non_interactive, "feat"])
    end
  end

  it "counts calls by verb name" do
    fake.select_pane("%1")
    fake.select_pane("%2")
    fake.unbind_key("F1")

    expect(fake.count(:select_pane)).to eq(2)
  end
end
