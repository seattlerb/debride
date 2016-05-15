#!/usr/bin/ruby -w

require "optparse"
require "set"
require "stringio"

require "ruby_parser"
require "sexp_processor"
require "path_expander"

# :stopdoc:
class File
  RUBY19 = "<3".respond_to? :encoding unless defined? RUBY19 # :nodoc:

  class << self
    alias :binread :read unless RUBY19
  end
end
# :startdoc:

##
# A static code analyzer that points out possible dead methods.

class Debride < MethodBasedSexpProcessor
  VERSION = "1.5.1" # :nodoc:
  PROJECT = "debride"

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
        rescue RuntimeError, LoadError => e
          warn "error loading #{plugin.inspect}: #{e.message}. skipping..."
        end
      end
    end

    @@plugins
  rescue
    []
  end

  def self.file_extensions
    %w[rb rake] + load_plugins
  end

  ##
  # Top level runner for bin/debride.

  def self.run args
    opt = parse_options args

    debride = Debride.new opt

    extensions = self.file_extensions
    glob = "**/*.{#{extensions.join(",")}}"
    expander = PathExpander.new(args, glob)
    files = expander.process
    excl  = debride.option[:exclude]
    files = expander.filter_files files, StringIO.new(excl.join "\n") if excl

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

  def process_rb path_or_io
    begin
      warn "Processing ruby: #{path_or_io}" if option[:verbose]

      case path_or_io
      when String then
        path, file = path_or_io, File.binread(path_or_io)
      when IO, StringIO then
        path, file = "(io)", path_or_io.read
      else
        raise "Unhandled type: #{path_or_io.class}:#{path_or_io.inspect}"
      end

      rp = RubyParser.for_current_ruby rescue RubyParser.new
      rp.process(file, path, option[:timeout])
    rescue Racc::ParseError => e
      warn "Parse Error parsing #{path}. Skipping."
      warn "  #{e.message}"
    rescue Timeout::Error
      warn "TIMEOUT parsing #{path}. Skipping."
    end
  end

  ##
  # Parse command line options and return a hash of parsed option values.

  def self.parse_options args
    options = {:whitelist => []}

    op = OptionParser.new do |opts|
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

      opts.on("-f", "--focus PATH", String, "Only report against this path") do |s|
        unless File.exist? s then
          abort "ERROR: --focus path #{s} doesn't exist."
        end

        s = "#{s.chomp "/"}/*" if File.directory?(s)

        options[:focus] = s
      end

      opts.on("-r", "--rails", "Add some rails call conversions.") do
        options[:rails] = true
      end

      opts.on("-v", "--verbose", "Verbose. Show progress processing files.") do
        options[:verbose] = true
      end
    end

    op.parse! args

    abort op.to_s if args.empty?

    options
  rescue OptionParser::InvalidOption => e
    warn op.to_s
    warn ""
    warn e.message
    exit 1
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
    self.option = { :whitelist => [] }.merge options
    self.known  = Hash.new { |h,k| h[k] = Set.new }
    self.called = Set.new
    self.map    = Hash.new { |h,k| h[k] = {} }
    super()
  end

  def klass_name # :nodoc:
    super.to_s
  end

  def plain_method_name # :nodoc:
    method_name.to_s.sub(/^::|#/, "").to_sym
  end

  def process_attrasgn(sexp)
    method_name = sexp[2]
    method_name = method_name.last if Sexp === method_name
    called << method_name
    process_until_empty sexp
    sexp
  end

  def record_method name, file, line
    signature = "#{klass_name}##{name}"
    method_locations[signature] = "#{file}:#{line}"
    map[klass_name][name] = signature
    known[name] << klass_name
  end

  def process_call sexp # :nodoc:
    method_name = sexp[2]

    case method_name
    when :new then
      method_name = :initialize
    when :alias_method_chain then
      # s(:call, nil, :alias_method_chain, s(:lit, :royale), s(:lit, :cheese))
      _, _, _, (_, new_name), _ = sexp
      if option[:rails] then
        file, line = sexp.file, sexp.line
        record_method new_name, file, line
      end
    when :attr_accessor then
      # s(:call, nil, :attr_accessor, s(:lit, :a1), ...)
      _, _, _, *args = sexp
      file, line = sexp.file, sexp.line
      args.each do |(_, name)|
        record_method name, file, line
        record_method "#{name}=".to_sym, file, line
      end
    when :attr_writer then
      # s(:call, nil, :attr_writer, s(:lit, :w1), ...)
      _, _, _, *args = sexp
      file, line = sexp.file, sexp.line
      args.each do |(_, name)|
        record_method "#{name}=".to_sym, file, line
      end
    when :attr_reader then
      # s(:call, nil, :attr_reader, s(:lit, :r1), ...)
      _, _, _, *args = sexp
      file, line = sexp.file, sexp.line
      args.each do |(_, name)|
        record_method name, file, line
      end
    when :send, :public_send, :__send__ then
      # s(:call, s(:const, :Seattle), :send, s(:lit, :raining?))
      _, _, _, msg_arg, * = sexp
      if Sexp === msg_arg && [:lit, :str].include?(msg_arg.sexp_type) then
        called << msg_arg.last.to_sym
      end
     when *RAILS_VALIDATION_METHODS then
       if option[:rails]
         possible_hash = sexp.last
         if Sexp === possible_hash && possible_hash.sexp_type == :hash
           possible_hash.sexp_body.each_slice(2) do |key, val|
             called << val.last        if val.first == :lit
             called << val.last.to_sym if val.first == :str
           end
         end
       end
     when *RAILS_DSL_METHODS then
       if option[:rails]
         # s(:call, nil, :before_save, s(:lit, :save_callback), s(:hash, ...))
         _, _, _, (_, new_name), possible_hash = sexp
         called << new_name
         if Sexp === possible_hash && possible_hash.sexp_type == :hash
           possible_hash.sexp_body.each_slice(2) do |key, val|
             next unless Sexp === val
             called << val.last        if val.first == :lit
             called << val.last.to_sym if val.first == :str
           end
         end
       end
    when /_path$/ then
      method_name = method_name.to_s[0..-6].to_sym if option[:rails]
    end

    called << method_name

    process_until_empty sexp

    sexp
  end

  def process_cdecl exp # :nodoc:
    _, name, val = exp
    process val

    signature = "#{klass_name}::#{name}"
    map[klass_name][name] = signature
    known[name] << klass_name

    file, line = exp.file, exp.line
    method_locations[signature] = "#{file}:#{line}"

    exp
  end

  def process_colon2 exp # :nodoc:
    _, lhs, name = exp
    process lhs

    called << name

    exp
  end

  def process_colon3 exp # :nodoc:
    _, name = exp

    called << name

    exp
  end

  def process_const exp # :nodoc:
    _, name = exp

    called << name

    exp
  end

  def process_defn sexp # :nodoc:
    super do
      map[klass_name][plain_method_name] = signature
      known[plain_method_name] << klass_name
      process_until_empty sexp
    end
  end

  def process_defs sexp # :nodoc:
    super do
      map[klass_name][plain_method_name] = signature
      known[plain_method_name] << klass_name
      process_until_empty sexp
    end
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

    not_called.reject! { |s| whitelist_regexp =~ s.to_s }

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
    focus = option[:focus]

    if focus then
      puts "Focusing on #{focus}"
      puts
    end

    puts "These methods MIGHT not be called:"

    missing.each do |klass, meths|
      bad = meths.map { |meth|
        location = method_locations[map[klass][meth]]
        path = location[/(.+):\d+$/, 1]

        next if focus and not File.fnmatch(focus, path)

        "  %-35s %s" % [meth, location]
      }
      bad.compact!
      next if bad.empty?

      puts
      puts klass
      puts bad.join "\n"
    end
  end

  RAILS_DSL_METHODS = [
    :after_action,
    :around_action,
    :before_action,

    # http://api.rubyonrails.org/v4.2.1/classes/ActiveRecord/Callbacks.html
    :after_commit,
    :after_create,
    :after_destroy,
    :after_find,
    :after_initialize,
    :after_rollback,
    :after_save,
    :after_touch,
    :after_update,
    :after_validation,
    :around_create,
    :around_destroy,
    :around_save,
    :around_update,
    :before_create,
    :before_destroy,
    :before_save,
    :before_update,
    :before_validation,

    # http://api.rubyonrails.org/classes/ActiveModel/Validations/ClassMethods.html#method-i-validate
    :validate,
  ]

  # http://api.rubyonrails.org/v4.2.1/classes/ActiveModel/Validations/HelperMethods.html
  RAILS_VALIDATION_METHODS = [
    :validates,
    :validates_absence_of,
    :validates_acceptance_of,
    :validates_confirmation_of,
    :validates_exclusion_of,
    :validates_format_of,
    :validates_inclusion_of,
    :validates_length_of,
    :validates_numericality_of,
    :validates_presence_of,
    :validates_size_of,
  ]
end
