# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Layout do
      describe Rect do
        describe ".zero" do
          it "builds a rect with every field at zero" do
            expect(described_class.zero).to eq(
              described_class.new(
                x: 0,
                y: 0,
                width: 0,
                height: 0
              )
            )
          end
        end
      end

      describe Constraint do
        describe ".percentage" do
          it "builds a percentage constraint" do
            expect(described_class.percentage(50)).to eq(
              described_class.new(
                kind: :percentage,
                value: 50
              )
            )
          end
        end

        describe ".fill" do
          it "builds a fill constraint" do
            expect(described_class.fill(1)).to eq(
              described_class.new(
                kind: :fill,
                value: 1
              )
            )
          end
        end
      end

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

        it "sizes a percentage row from the area and gives the leftover to the fill row" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 40,
            height: 10
          )
          chunks = described_class.vertical(
            [
              Constraint.percentage(30),
              Constraint.fill(1)
            ]
          ).split(area)

          expect(chunks.map(&:height)).to eq([3, 7])
        end

        it "keeps the sizes as-is when the constraints exactly fill the area" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 40,
            height: 10
          )
          chunks = described_class.vertical(
            [
              Constraint.length(4),
              Constraint.length(6)
            ]
          ).split(area)

          expect(chunks.map(&:height)).to eq([4, 6])
        end

        it "leaves the leftover space unassigned when no row is flexible" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 40,
            height: 10
          )
          chunks = described_class.vertical(
            [
              Constraint.length(3),
              Constraint.length(3)
            ]
          ).split(area)

          expect(chunks.map(&:height)).to eq([3, 3])
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
