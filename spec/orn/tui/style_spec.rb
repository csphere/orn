# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Style do
      it "builds foreground, background, and bold without mutating the base" do
        base = described_class.default
        styled = base.fg(Color::RED).bg(Color::WHITE).bold

        aggregate_failures do
          expect(styled.foreground).to eq(Color::RED)
          expect(styled.background).to eq(Color::WHITE)
          expect(styled.bold?).to be(true)
          expect(base.foreground).to be_nil
          expect(base.bold?).to be(false)
        end
      end

      it "compares equal by resolved colours and weight" do
        one = described_class.default.fg(Color::RED)
        two = described_class.default.fg(Color::RED)

        expect(one).to eq(two)
      end

      describe "#hash" do
        it "hashes equal styles to the same value" do
          one = described_class.default.fg(Color::RED).bold
          two = described_class.default.fg(Color::RED).bold

          expect(one.hash).to eq(two.hash)
        end

        it "hashes differing styles to different values" do
          plain = described_class.default
          bolded = described_class.default.bold

          expect(plain.hash).not_to eq(bolded.hash)
        end

        it "collides equal styles onto one Hash key" do
          style_counts = Hash.new(0)
          style_counts[described_class.default.fg(Color::RED)] += 1
          style_counts[described_class.default.fg(Color::RED)] += 1
          style_counts[described_class.default.fg(Color::GREEN)] += 1

          expect(style_counts).to eq(
            described_class.default.fg(Color::RED) => 2,
            described_class.default.fg(Color::GREEN) => 1
          )
        end
      end
    end
  end
end
