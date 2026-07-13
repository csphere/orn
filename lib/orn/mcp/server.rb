# frozen_string_literal: true

require "json"

module Orn
  module Mcp
    # MCP server: exposes orn commands as tools over line-delimited JSON-RPC on
    # stdio.
    module Server
      # Runs the server loop on stdin/stdout until EOF.
      def self.serve
        serve_io($stdin, $stdout)
      end

      # Request loop over one JSON message per line. Notifications (no `id`) are
      # ignored, unparseable lines get a -32700 response, and neither ends the
      # loop; only EOF ends it.
      def self.serve_io(reader, writer)
        reader.each_line do |line|
          line = line.chomp
          next if line.strip.empty?

          request = parse_request(line)
          if request.nil?
            write(writer, Protocol.error_response(nil, -32_700, "Parse error: invalid JSON-RPC request"))
            next
          end

          next unless request.key?("id")

          write(writer, handle(request["id"], request["method"], request["params"]))
        end
      end

      # Parses one line into a request hash, or nil when it is not a well-formed
      # JSON-RPC request object.
      def self.parse_request(line)
        parsed = JSON.parse(line)
        parsed.is_a?(Hash) && parsed["method"].is_a?(String) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def self.handle(id, method, params)
        case method
        when "initialize" then Protocol.success_response(id, Protocol.initialize_result)
        when "tools/list" then Protocol.success_response(id, { "tools" => Tools.definitions })
        when "tools/call" then handle_tools_call(id, params)
        else Protocol.error_response(id, -32_601, "Method not found: #{method}")
        end
      end

      # Tool failures are reported inside a successful response via `isError`,
      # not as JSON-RPC errors; only a missing `name` param is protocol-level.
      def self.handle_tools_call(id, params)
        name = params.is_a?(Hash) ? params["name"] : nil
        unless name.is_a?(String)
          return Protocol.error_response(id, -32_602, "Invalid params: missing required field `name`")
        end

        arguments = params["arguments"]
        arguments = {} unless arguments.is_a?(Hash)
        Protocol.success_response(id, Tools.dispatch(name, arguments))
      end

      def self.write(writer, response)
        writer.write(Protocol.encode(response))
        writer.write("\n")
        writer.flush
      end

      private_class_method :parse_request, :handle, :handle_tools_call, :write
    end
  end
end
