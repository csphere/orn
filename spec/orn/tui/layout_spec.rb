# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Layout do
      describe "#split vertically" do
        it "stacks fixed-length rows and hands the rest to the min row" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 40,
            height: 12
          )
          chunks = described_class.vertical(
            [
              Constraint.length(2),
              Constraint.min(1),
              Constraint.length(1),
              Constraint.length(0),
              Constraint.length(2)
            ]
          ).split(area)

          expect(chunks.map(&:height)).to eq([2, 7, 1, 0, 2])
        end

        it "positions the error row at height minus three" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 40,
            height: 12
          )
          chunks = described_class.vertical(
            [
              Constraint.length(2),
              Constraint.min(1),
              Constraint.length(1),
              Constraint.length(0),
              Constraint.length(2)
            ]
          ).split(area)

          expect(chunks[2].y).to eq(area.height - 3)
        end

        it "trims an overflow from the trailing rows when constraints exceed the area" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 40,
            height: 3
          )
          chunks = described_class.vertical(
            [
              Constraint.length(2),
              Constraint.length(2),
              Constraint.length(2)
            ]
          ).split(area)

          expect(chunks.map(&:height)).to eq([2, 1, 0])
        end
      end

      describe "#split horizontally" do
        it "splits by width, giving the remainder to the min column" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 30,
            height: 5
          )
          chunks = described_class.horizontal(
            [
              Constraint.length(10),
              Constraint.min(1)
            ]
          ).split(area)

          expect(chunks.map(&:width)).to eq([10, 20])
        end
      end
    end
  end
end
