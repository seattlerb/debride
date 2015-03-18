#!/usr/bin/ruby -w

$:.unshift "../../sexp_processor/dev/lib"

require "ruby_parser"
require "sexp_processor"
require "optparse"
require "set"

##
# A static code analyzer that points out possible dead methods.

class Debride < MethodBasedSexpProcessor
  VERSION = "1.0.0" # :nodoc:

  ##
  # Top level runner for bin/debride.

  def self.run args
    opt = parse_options args

    callers = Debride.new opt

    expand_dirs_to_files(args).each do |path|
      warn "processing: #{path}" if opt[:verbose]
      parser = RubyParser.new
      callers.process parser.process File.read(path), path
    end

    callers
  end

  ##
  # Parse command line options and return a hash of parsed option values.

  def self.parse_options args
    options = {:whitelist => []}

    OptionParser.new do |opts|
      opts.banner  = "debride [options] files_or_dirs"
      opts.version = Debride::VERSION

      opts.separator ""
      opts.separator "Specific options:"
      opts.separator ""

      opts.on("-h", "--help", "Display this help.") do
        puts opts
        exit
      end

      opts.on("-w", "--whitelist FILE", String, "Whitelist these messages.") do |s|
        options[:whitelist] = File.read(s).split(/\n+/) rescue []
      end

      opts.on("-v", "--verbose", "Verbose. Show progress processing files.") do
        options[:verbose] = true
      end

      opts.parse! args
    end

    options
  end

  ##
  # A collection of know methods, mapping method name to implementing classes.

  attr_accessor :known

  ##
  # A set of called method names.

  attr_accessor :called

  ##
  # Command-line options.

  attr_accessor :option
  attr_accessor :map # :nodoc: # TODO: retire and use method_locations

  ##
  # Create a new Debride instance w/ +options+

  def initialize options = {}
    self.option = options
    self.known  = Hash.new { |h,k| h[k] = Set.new }
    self.called = Set.new
    self.map    = Hash.new { |h,k| h[k] = {} }
    super()
  end

  def klass_name # :nodoc:
    super.to_s
  end

  def method_name # :nodoc:
    super.to_s.sub(/^::|#/, "").to_sym
  end

  def process_defn sexp # :nodoc:
    super do
      map[klass_name][method_name] = signature
      known[method_name] << klass_name
      process_until_empty sexp
    end
  end

  def process_defs sexp # :nodoc:
    super do
      map[klass_name][method_name] = signature
      known[method_name] << klass_name
      process_until_empty sexp
    end
  end

  def process_call sexp # :nodoc:
    method_name = sexp[2]
    method_name = :initialize if method_name == :new

    if method_name == :alias_method_chain
      known[sexp[3]] << klass_name
    end

    called << method_name

    process_until_empty sexp

    sexp
  end

  ##
  # Calculate the difference between known methods and called methods.

  def missing
    whitelist_regexps = []

    option[:whitelist].each do |s|
      if s =~ /^\/.+?\/$/ then
        whitelist_regexps << Regexp.new(s[1..-2])
      else
        called << s.to_sym
      end
    end

    not_called = known.keys - called.to_a

    whitelist_regexp = Regexp.union whitelist_regexps
    not_called.reject! { |s| whitelist_regexp =~ s }

    by_class = Hash.new { |h,k| h[k] = [] }

    not_called.each do |meth|
      known[meth].each do |klass|
        by_class[klass] << meth
      end
    end

    by_class.each do |klass, meths|
      by_class[klass] = meths.sort_by(&:to_s)
    end

    by_class.sort_by { |k,v| k }
  end

  ##
  # Print out a report of suspects.

  def report
    puts "These methods MIGHT not be called:"

    missing.each do |klass, meths|
      puts
      puts klass
      meths.each do |meth|
        puts "  %-35s %s" % [meth, method_locations[map[klass][meth]]]
      end
    end
  end
end
