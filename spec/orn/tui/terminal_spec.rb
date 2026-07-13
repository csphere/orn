# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Terminal do
      it "renders through a frame and returns the flushed buffer" do
        terminal = described_class.new(TestBackend.new(10, 2))

        buffer = terminal.draw do |frame|
          frame.render_widget(Paragraph.line(Line.raw("hello")), frame.area)
        end

        expect(buffer.to_s).to include("hello")
      end

      it "returns scripted key events from poll, then nil" do
        backend = TestBackend.new(5, 1)
        backend.feed(KeyEvent.char("q"), KeyEvent.key(:enter))
        terminal = described_class.new(backend)

        aggregate_failures do
          expect(terminal.poll(0).char).to eq("q")
          expect(terminal.poll(0).code).to eq(:enter)
          expect(terminal.poll(0)).to be_nil
        end
      end
    end
  end
end
