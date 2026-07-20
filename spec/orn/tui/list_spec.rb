# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe List do
      def items(count)
        (0...count).map { |i| ListItem.new(Line.raw(format("row-%02d", i))) }
      end

      it "scrolls so a selection below the viewport stays visible" do
        area = Rect.new(
          x: 0,
          y: 0,
          width: 20,
          height: 4
        )
        buffer = Buffer.new(area)
        state = ListState.new
        state.select(19)

        described_class.new(items(20)).render(
          area,
          buffer,
          state
        )

        aggregate_failures do
          expect(state.offset).to eq(16)
          expect(buffer.to_s).to include("row-19")
          expect(buffer.to_s).not_to include("row-00")
        end
      end

      it "draws nothing and keeps the scroll state for a zero-height area" do
        zero_area = Rect.new(
          x: 0,
          y: 0,
          width: 20,
          height: 0
        )
        buffer_area = Rect.new(
          x: 0,
          y: 0,
          width: 20,
          height: 4
        )
        buffer = Buffer.new(buffer_area)
        state = ListState.new
        state.select(4)

        described_class.new(items(5)).render(
          zero_area,
          buffer,
          state
        )

        aggregate_failures do
          expect(buffer.to_s.strip).to be_empty
          expect(state.offset).to eq(0)
        end
      end

      describe ".follow_offset" do
        it "pulls the offset up to a selection above the viewport" do
          expect(
            described_class.follow_offset(
              10,
              3,
              4
            )
          ).to eq(3)
        end

        it "leaves the offset alone when the selection is already visible" do
          expect(
            described_class.follow_offset(
              2,
              3,
              4
            )
          ).to eq(2)
        end

        it "keeps the offset when nothing is selected" do
          expect(
            described_class.follow_offset(
              5,
              nil,
              4
            )
          ).to eq(5)
        end
      end
    end
  end
end
