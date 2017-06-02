module Formatter
  class YamlFormatter < BaseFormatter
    FORMAT = "  - %-35s # %s".freeze

    def self.format(meth, location)
      FORMAT % [meth, location]
    end

    def self.put_log(klass, bad)
      puts
      puts "#{klass}:"
      puts bad.join "\n"
    end
  end
end
