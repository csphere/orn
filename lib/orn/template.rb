# frozen_string_literal: true

module Orn
  # A bundled template file, located by its path relative to the gem's
  # `templates/` directory (for example "CLAUDE.md" or "config.yaml").
  class Template
    def initialize(name)
      @name = name
    end

    # Returns the raw template contents, raising Orn::Error when the template
    # does not exist.
    def read
      raise Orn::Error, "Template not found: #{@name}" unless File.file?(path)

      File.read(path)
    end

    private

    def path
      File.join(Orn.root, "templates", @name)
    end
  end
end
