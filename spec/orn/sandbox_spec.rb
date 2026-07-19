# frozen_string_literal: true

RSpec.describe Orn::Sandbox do
  describe Orn::Sandbox::PortMapping do
    it "displays as host:container" do
      expect(
        described_class.new(
          host: 3042,
          container: 3000
        ).to_s
      ).to eq("3042:3000")
    end
  end

  describe Orn::Sandbox::Check do
    it "builds a passing error check" do
      check = described_class.pass("test", "ok")

      expect(check).to have_attributes(
        passed: true,
        kind: :error,
        name: "test",
        message: "ok"
      )
    end

    it "builds a failing error check" do
      check = described_class.fail("test", "bad")

      expect(check).to have_attributes(
        passed: false,
        kind: :error,
        name: "test",
        message: "bad"
      )
    end

    it "builds a failing warning check" do
      check = described_class.warning(
        "test",
        false,
        "warn msg"
      )

      expect(check).to have_attributes(
        passed: false,
        kind: :warning,
        name: "test",
        message: "warn msg"
      )
    end

    it "builds a passing warning check" do
      check = described_class.warning(
        "test",
        true,
        "ok msg"
      )

      expect(check).to have_attributes(
        passed: true,
        kind: :warning
      )
    end

    it "serializes kind as a lowercase string" do
      aggregate_failures do
        expect(
          described_class.warning(
            "test",
            false,
            "msg"
          ).to_json_hash["kind"]
        ).to eq("warning")
        expect(described_class.fail("test", "msg").to_json_hash["kind"]).to eq("error")
      end
    end
  end
end
