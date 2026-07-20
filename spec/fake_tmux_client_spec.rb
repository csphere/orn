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
      width_pct: 67,
      focus: true
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
        width_pct: 67,
        focus: true
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

  # The fakes mirror hand-written verb surfaces; these parity checks catch a
  # renamed or re-signed verb on the real class that would otherwise leave
  # every fake-backed spec green while production breaks.
  describe "parity with Orn::Tmux::Client" do
    # Seed accessors (windows=, panes=, ...) and recording helpers exist only
    # on the fake.
    def harness_method?(fake_class, name)
      name.end_with?("=") || fake_class.method_defined?("#{name}=") || %i[calls count].include?(name)
    end

    def required_count(params)
      params.count { |kind, _| kind == :req }
    end

    def keyword_names(params)
      params.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
    end

    def signature_compatible?(real_params, fake_params)
      return false unless required_count(real_params) == required_count(fake_params)

      accepts_keyrest = fake_params.any? { |kind, _| kind == :keyrest }
      accepts_keyrest || (keyword_names(real_params) - keyword_names(fake_params)).empty?
    end

    it "fakes every real client verb with a compatible signature" do
      Orn::Tmux::Client.public_instance_methods(false).each do |verb|
        expect(described_class.method_defined?(verb)).to be(true), "FakeTmuxClient is missing ##{verb}"
        compatible = signature_compatible?(
          Orn::Tmux::Client.instance_method(verb).parameters,
          described_class.instance_method(verb).parameters
        )
        expect(compatible).to be(true), "FakeTmuxClient##{verb} signature drifted from the real client"
      end
    end

    it "defines no dead verbs the real client lacks" do
      described_class.public_instance_methods(false).each do |verb|
        next if harness_method?(described_class, verb)

        expect(Orn::Tmux::Client.method_defined?(verb)).to be(true),
          "FakeTmuxClient##{verb} has no real counterpart"
      end
    end
  end

  describe "FakeHub parity with Orn::TUI::Hub" do
    # FakeHub is a partial fake by design (unfaked verbs raise
    # NoMethodError), so only the fake-to-real direction is checked.
    it "only fakes verbs the real hub defines, with matching arity" do
      FakeHub.public_instance_methods(false).each do |verb|
        next if verb.to_s.end_with?("=") || %i[calls count fail_on].include?(verb)

        expect(Orn::TUI::Hub.method_defined?(verb)).to be(true), "FakeHub##{verb} has no real counterpart"
        real_arity = Orn::TUI::Hub.instance_method(verb).parameters.length
        expect(FakeHub.instance_method(verb).parameters.length).to eq(real_arity),
          "FakeHub##{verb} arity drifted from the real hub"
      end
    end
  end
end
