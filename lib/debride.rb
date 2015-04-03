#!/usr/bin/ruby -w

require "ruby_parser"
require "sexp_processor"
require "optparse"
require "set"

##
# A static code analyzer that points out possible dead methods.

class Debride < MethodBasedSexpProcessor
  VERSION = "1.2.0" # :nodoc:
  PROJECT = "debride"

  def self.expand_dirs_to_files *dirs # TODO: push back up to sexp_processor
    extensions = self.file_extensions

    dirs.flatten.map { |p|
      if File.directory? p then
        Dir[File.join(p, "**", "*.{#{extensions.join(",")}}")]
      else
        p
      end
    }.flatten.map { |s| s.sub(/^\.\//, "") } # strip "./" from paths
  end

  def self.load_plugins proj = PROJECT
    unless defined? @@plugins then
      @@plugins = []

      task_re = /#{PROJECT}_task/o
      plugins = Gem.find_files("#{PROJECT}_*.rb").reject { |p| p =~ task_re }

      plugins.each do |plugin|
        plugin_name = File.basename(plugin, ".rb").sub(/^#{PROJECT}_/o, "")
        next if @@plugins.include? plugin_name
        begin
          load plugin
          @@plugins << plugin_name
        rescue LoadError => e
          warn "error loading #{plugin.inspect}: #{e.message}. skipping..."
        end
      end
    end

    @@plugins
  rescue
    # ignore
  end

  def self.file_extensions
    %w[rb rake] + load_plugins
  end

  ##
  # Top level runner for bin/debride.

  def self.run args
    opt = parse_options args

    debride = Debride.new opt

    files = expand_dirs_to_files(args)
    files -= expand_dirs_to_files(debride.option[:exclude]) if debride.option[:exclude]

    debride.run(files)
    debride
  end

  def run(*files)
    files.flatten.each do |file|
      warn "Processing #{file}" if option[:verbose]

      ext = File.extname(file).sub(/^\./, "")
      ext = "rb" if ext.nil? || ext.empty?
      msg = "process_#{ext}"

      unless respond_to? msg then
        warn "  Unknown file type: #{ext}, defaulting to ruby" if option[:verbose]
        msg = "process_rb"
      end

      begin
        process send(msg, file)
      rescue RuntimeError, SyntaxError => e
        warn "  skipping #{file}: #{e.message}"
      end
    end
  end

  def process_rb file
    begin
      RubyParser.new.process(File.binread(file), file, option[:timeout])
    rescue Timeout::Error
      warn "TIMEOUT parsing #{file}. Skipping."
    end
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

      opts.on("-e", "--exclude FILE1,FILE2,ETC", Array, "Exclude files or directories in comma-separated list.") do |list|
        options[:exclude] = list
      end

      opts.on("-w", "--whitelist FILE", String, "Whitelist these messages.") do |s|
        options[:whitelist] = File.read(s).split(/\n+/) rescue []
      end

      opts.on("-r", "--rails", "Add some rails call conversions.") do
        options[:rails] = true
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

    case method_name
    when :new then
      method_name = :initialize
    when :alias_method_chain then
      known[sexp[3]] << klass_name if option[:rails]
    when /_path$/ then
      method_name = method_name.to_s[0..-6].to_sym if option[:rails]
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
