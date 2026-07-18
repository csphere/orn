# frozen_string_literal: true

require "io/console"

module Orn
  module TUI
    # A decoded key press. `code` is a symbol (`:char`, `:enter`, `:esc`,
    # `:backspace`, `:up`, `:down`); `char` carries the character when
    # `code == :char`. The decoded key event the event loops match on.
    KeyEvent = Data.define(:code, :char) do
      def self.char(character)
        new(
          code: :char,
          char: character
        )
      end

      def self.key(code)
        new(
          code: code,
          char: nil
        )
      end
    end

    # Drives a render pass into a fresh back buffer each tick and flushes it to
    # a backend. The backend is either the
    # in-memory `TestBackend` or the real `TermBackend`.
    class Terminal
      attr_reader :backend

      def initialize(backend)
        @backend = backend
      end

      # Build a fresh buffer, run the render block against a `Frame` over it,
      # flush to the backend, and return the buffer (tests inspect it).
      def draw
        buffer = Buffer.new(@backend.area)
        yield Frame.new(buffer)
        @backend.flush(buffer)
        buffer
      end

      # Wait up to `timeout` seconds for a key press, returning a `KeyEvent` or
      # nil on timeout.
      def poll(timeout)
        @backend.poll(timeout)
      end

      # The current drawable area, re-read each tick so the event loop can
      # notice a terminal resize.
      def area
        @backend.area
      end

      # Blank the whole screen. The event loop calls this on resize so a
      # shrunk terminal keeps no stale rows from the taller layout.
      def clear
        @backend.clear
      end
    end

    # In-memory backend for tests: keeps the last flushed buffer and replays a
    # scripted queue of key events. No terminal is touched.
    class TestBackend
      # A scripted terminal resize: when `poll` reaches one it changes the
      # reported area and returns nil, standing in for a size-change wakeup
      # that carries no key press.
      Resize = Data.define(:width, :height)

      attr_reader :area,
        :buffer,
        :clears

      def initialize(width, height)
        @area = Rect.new(
          x: 0,
          y: 0,
          width: width,
          height: height
        )
        @buffer = Buffer.new(@area)
        @events = []
        @clears = 0
      end

      def flush(buffer)
        @buffer = buffer
      end

      # Count clear calls so tests can assert a resize triggered a full redraw.
      def clear
        @clears += 1
      end

      # Queue key events for `poll` to return, in order.
      def feed(*events)
        @events.concat(events)
      end

      # Queue a resize into the same stream as `feed`, so tests can script a
      # size change between key presses.
      def feed_resize(width, height)
        @events << Resize.new(
          width: width,
          height: height
        )
      end

      def poll(_timeout)
        event = @events.shift
        return event unless event.is_a?(Resize)

        @area = Rect.new(
          x: 0,
          y: 0,
          width: event.width,
          height: event.height
        )
        nil
      end
    end

    # Real-terminal backend over stdlib `io/console`: raw mode, the alternate
    # screen, and a hidden cursor while running; ANSI diff-free full redraws on
    # flush; and `IO.select`-timed key polling. Restoration is idempotent and
    # wired to `ensure`/`at_exit`/signals by the caller so a crash never leaves
    # the terminal wedged. Validated interactively (no unit tests touch a tty).
    class TermBackend
      ENTER_ALT = "\e[?1049h"
      LEAVE_ALT = "\e[?1049l"
      HIDE_CURSOR = "\e[?25l"
      SHOW_CURSOR = "\e[?25h"

      # Fixed escape/control byte sequences mapped to their key codes.
      KEY_SEQUENCES = {
        "\e[A" => :up,
        "\e[B" => :down,
        "\r" => :enter,
        "\n" => :enter,
        "\e" => :esc,
        "\x7f" => :backspace,
        "\b" => :backspace
      }.freeze

      def initialize(input: $stdin, output: $stdout)
        @input = input
        @output = output
        @started = false
      end

      def area
        rows, cols = console_size
        Rect.new(
          x: 0,
          y: 0,
          width: cols,
          height: rows
        )
      end

      # Enter raw mode + alt screen. Idempotent.
      def start
        return if @started

        @input.raw! if @input.tty?
        @output.write(ENTER_ALT + HIDE_CURSOR)
        @output.flush
        @started = true
      end

      # Restore cooked mode, the main screen, and the cursor. Idempotent, so it
      # is safe from both `ensure` and a signal handler.
      def stop
        return unless @started

        @output.write(SHOW_CURSOR + LEAVE_ALT)
        @output.flush
        @input.cooked! if @input.tty?
        @started = false
      end

      def flush(buffer)
        @output.write("\e[H#{render(buffer)}")
        @output.flush
      end

      # Blank the whole screen. Used on resize so a shrunk terminal keeps no
      # stale rows below the new layout.
      def clear
        @output.write("\e[2J")
        @output.flush
      end

      # Return a `KeyEvent` if a key arrives within `timeout` seconds, else nil.
      def poll(timeout)
        return nil unless @input.wait_readable(timeout)

        decode(read_available)
      end

      # Serialise the whole buffer to ANSI: move to each row, emit runs of
      # same-styled cells, and clear to end of line.
      def render(buffer)
        area = buffer.area
        rows = (0...area.height).map do |row|
          "\e[#{row + 1};1H#{render_row(
            buffer,
            area,
            row
          )}\e[K"
        end
        rows.join
      end

      private

      def render_row(buffer, area, row)
        out = +""
        last_style = nil
        (0...area.width).each do |col|
          cell = buffer.cell(area.x + col, area.y + row)
          style = [cell.fg, cell.bg, cell.bold]
          out << sgr(cell) unless style == last_style
          out << cell.symbol
          last_style = style
        end
        out << "\e[0m"
      end

      # SGR escape resetting then setting a cell's foreground, background, and
      # bold. `Color::CODES` is the foreground table; background is +10.
      def sgr(cell)
        codes = [0]
        codes << 1 if cell.bold
        codes << Color::CODES.fetch(cell.fg, 39)
        codes << (Color::CODES.fetch(cell.bg, 39) + 10)
        "\e[#{codes.join(";")}m"
      end

      def console_size
        @input.winsize
      rescue IOError, Errno::ENOTTY, NoMethodError
        [24, 80]
      end

      def read_available
        bytes = +""
        bytes << @input.read_nonblock(64) while @input.wait_readable(0)
        bytes
      rescue IO::WaitReadable, EOFError
        bytes
      end

      # Map a raw byte sequence to a `KeyEvent`. Handles the escape sequences
      # orn's key handlers match: arrows, plain Enter/Esc/Backspace, and
      # printable characters.
      def decode(bytes)
        return nil if bytes.empty?

        code = KEY_SEQUENCES[bytes]
        return KeyEvent.key(code) if code

        char = bytes[0]
        char.match?(/[[:print:]]/) ? KeyEvent.char(char) : nil
      end
    end
  end
end
