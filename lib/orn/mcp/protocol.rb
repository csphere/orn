# frozen_string_literal: true

require "json"

module Orn
  module Mcp
    # JSON-RPC wire format for the MCP server (protocol version 2024-11-05).
    #
    # Key ordering: the envelope (`jsonrpc`, `id`, `result`/`error`) stays in
    # declaration order via an insertion-ordered hash, while the result
    # payload's keys are deep-sorted recursively before encoding, so responses
    # are stable and comparable.
    module Protocol
      PROTOCOL_VERSION = "2024-11-05"

      # A successful response: the result payload's keys are deep-sorted for a
      # stable key order.
      def self.success_response(id, result)
        { "jsonrpc" => "2.0", "id" => id, "result" => deep_sort(result) }
      end

      # An error response. The error object keeps declaration order (code,
      # message); it is not deep-sorted.
      def self.error_response(id, code, message)
        { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
      end

      # The `initialize` handshake result.
      def self.initialize_result
        {
          "protocolVersion" => PROTOCOL_VERSION,
          "capabilities" => { "tools" => {} },
          "serverInfo" => { "name" => "orn", "version" => Orn::VERSION }
        }
      end

      # A tool-call result carrying `text`; `isError` is omitted on success.
      def self.tool_success(text)
        { "content" => [{ "type" => "text", "text" => text }] }
      end

      # A tool-call result marking a tool-level failure (the JSON-RPC response
      # itself stays successful).
      def self.tool_error(text)
        { "content" => [{ "type" => "text", "text" => text }], "isError" => true }
      end

      # Recursively sort hash keys (arrays keep their order) for a
      # stable, comparable order.
      def self.deep_sort(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, deep_sort(value[key])] }
        when Array then value.map { |element| deep_sort(element) }
        else value
        end
      end

      # Compact JSON for one response line (no spaces).
      def self.encode(response)
        JSON.generate(response)
      end
    end
  end
end
