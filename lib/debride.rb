#!/usr/bin/ruby -w

require "optparse"
require "set"
require "stringio"

require "ruby_parser"
require "sexp_processor"
require "path_expander"

##
# A static code analyzer that points out possible dead methods.

class Debride < MethodBasedSexpProcessor
  VERSION = "1.10.1" # :nodoc:
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
    %w[rb rake jbuilder] + load_plugins
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
    excl.map! { |fd| File.directory?(fd) ? "#{fd}/" : fd } if excl

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
  rescue Racc::ParseError, RegexpError => e
    warn "Parse Error parsing #{path}. Skipping."
    warn "  #{e.message}"
  rescue Timeout::Error
    warn "TIMEOUT parsing #{path}. Skipping."
  end

  ##
  # Parse command line options and return a hash of parsed option values.

  def self.parse_options args
    options = {
      :whitelist => [],
      :format => :text,
    }

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

      opts.on("-r", "--graphql", "Add some graphql-ruby call conversions.") do
        options[:graphql] = true
      end

      opts.on("-m", "--minimum N", Integer, "Don't show hits less than N locs.") do |n|
        options[:minimum] = n
      end

      opts.on("-v", "--verbose", "Verbose. Show progress processing files.") do
        options[:verbose] = true
      end

      opts.on "--json" do
        options[:format] = :json
      end

      opts.on "--yaml" do
        options[:format] = :yaml
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

  ##
  # Create a new Debride instance w/ +options+

  def initialize options = {}
    self.option = { :whitelist => [] }.merge options
    self.known  = Hash.new { |h,k| h[k] = Set.new }
    self.called = Set.new
    super()
  end

  def klass_name # :nodoc:
    super.to_s
  end

  def plain_method_name # :nodoc:
    method_name.to_s.sub(/^::|#/, "").to_sym
  end

  def process_attrasgn(sexp)
    _, _, method_name, * = sexp
    method_name = method_name.last if Sexp === method_name
    called << method_name
    process_until_empty sexp
    sexp
  end

  # handle &&=, ||=, etc
  def process_op_asgn2(sexp)
    _, _, method_name, * = sexp
    called << method_name
    process_until_empty sexp
    sexp
  end

  def record_method name, file, line
    signature = "#{klass_name}##{name}"
    method_locations[signature] = "#{file}:#{line}"
    known[name] << klass_name
  end

  def process_call sexp # :nodoc:
    _, _, method_name, * = sexp

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
        if Sexp === name then
          process name
          next
        end
        record_method name, file, line
        record_method "#{name}=".to_sym, file, line
      end
    when :attr_writer then
      # s(:call, nil, :attr_writer, s(:lit, :w1), ...)
      _, _, _, *args = sexp
      file, line = sexp.file, sexp.line
      args.each do |(_, name)|
        if Sexp === name then
          process name
          next
        end
        record_method "#{name}=".to_sym, file, line
      end
    when :attr_reader then
      # s(:call, nil, :attr_reader, s(:lit, :r1), ...)
      _, _, _, *args = sexp
      file, line = sexp.file, sexp.line
      args.each do |(_, name)|
        if Sexp === name then
          process name
          next
        end
        record_method name, file, line
      end
    when :send, :public_send, :__send__, :try, :const_get then
      # s(:call, s(:const, :Seattle), :send, s(:lit, :raining?))
      _, _, _, msg_arg, * = sexp
      if Sexp === msg_arg && [:lit, :str].include?(msg_arg.sexp_type) then
        called << msg_arg.last.to_sym
      end
    when :delegate then
      # s(:call, nil, :delegate, ..., s(:hash, s(:lit, :to), s(:lit, :delegator)))
      possible_hash = sexp.last
      if Sexp === possible_hash && possible_hash.sexp_type == :hash
        possible_hash.sexp_body.each_slice(2) do |key, val|
          next unless key == s(:lit, :to)
          next unless Sexp === val

          called << val.last        if val.sexp_type == :lit
          called << val.last.to_sym if val.sexp_type == :str
        end
      end
    when :method then
      # s(:call, nil, :method, s(:lit, :foo))
      _, _, _, msg_arg, * = sexp
      if Sexp === msg_arg && [:lit, :str].include?(msg_arg.sexp_type) then
        called << msg_arg.last.to_sym
      end
    when *RAILS_DSL_METHODS, *RAILS_VALIDATION_METHODS then
      if option[:rails]
        # s(:call, nil, :before_save, s(:lit, :save_callback), s(:hash, ...))
        if RAILS_DSL_METHODS.include?(method_name)
          _, _, _, (_, new_name), * = sexp
          called << new_name if new_name
        end
        possible_hash = sexp.last
        if Sexp === possible_hash && possible_hash.sexp_type == :hash
          possible_hash.sexp_body.each_slice(2) do |key, val|
            next unless Sexp === val
            called << val.last        if val.sexp_type == :lit
            called << val.last.to_sym if val.sexp_type == :str
          end
        end
      end
    when *RAILS_MACRO_METHODS
      # s(:call, nil, :has_one, s(:lit, :has_one_relation), ...)
      _, _, _, (_, name), * = sexp

      # try to detect route scope vs model scope
      if context.include? :module or context.include? :class then
        file, line = sexp.file, sexp.line
        record_method name, file, line
      end
    when *GRAPHQL_OBJECT_METHODS then
      if option[:graphql]
        # s(:call, nil, :field, s(:lit, :field_name), ...)
        _, _, _, (_, name), * = sexp

        if context.include? :module or context.include? :class then
          method_name = name
        end
      end
    when /_path$/ then
      method_name = method_name.to_s.delete_suffix("_path").to_sym if option[:rails]
    when /^deliver_/ then
      method_name = method_name.to_s.delete_prefix("deliver_").to_sym if option[:rails]
    end

    # check if the call has a block shorthand argument, etc. E.g. for `.each(&:empty?)`, `empty?` is called
    sexp.each do |arg|
      next unless Sexp === arg
      next unless arg.sexp_type == :block_pass
      _, block = arg
      next unless Sexp === block
      next unless block.sexp_type == :lit
      called << block.last
    end

    called << method_name

    process_until_empty sexp

    sexp
  end

  def process_cdecl exp # :nodoc:
    _, name, val = exp

    name = name_to_string process name if Sexp === name

    process val

    signature = "#{klass_name}::#{name}"

    known[name] << klass_name

    file, line = exp.file, exp.line
    method_locations[signature] = "#{file}:#{line}"

    exp
  end

  def name_to_string exp
    case exp.sexp_type
    when :const then
      exp.last.to_s
    when :colon2 then
      _, lhs, rhs = exp
      "#{name_to_string lhs}::#{rhs}"
    when :colon3 then
      _, rhs = exp
      "::#{rhs}"
    when :self then # wtf?
      "self"
    else
      raise "Not handled: #{exp.inspect}"
    end
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
      known[plain_method_name] << klass_name
      process_until_empty sexp
    end
  end

  def process_defs sexp # :nodoc:
    super do
      known[plain_method_name] << klass_name
      process_until_empty sexp
    end
  end

  alias process_safe_call process_call

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

  def missing_locations
    focus = option[:focus]

    missing.map { |klass, meths|
      bad = meths.map { |meth|
        location =
          method_locations["#{klass}##{meth}"] ||
          method_locations["#{klass}::#{meth}"]

        if focus then
          path = location[/(.+):\d+/, 1]

          next unless File.fnmatch(focus, path)
        end

        [meth, location]
      }.compact

      [klass, bad]
    }
      .to_h
      .reject { |k,v| v.empty? }
  end

  ##
  # Print out a report of suspects.

  def report io = $stdout
    focus = option[:focus]
    type  = option[:format] || :text

    send "report_#{type}", io, focus, missing_locations
  end

  def report_text io, focus, missing
    if focus then
      io.puts "Focusing on #{focus}"
      io.puts
    end

    io.puts "These methods MIGHT not be called:"

    total = 0

    missing.each do |klass, meths|
      bad = meths.map { |(meth, location)|
        loc = if location then
                l0, l1 = location.split(/:/).last.scan(/\d+/).flatten.map(&:to_i)
                l1 ||= l0
                l1 - l0 + 1
              else
                1
              end

        next if option[:minimum] && loc < option[:minimum]

        total += loc

        "  %-35s %s (%d)" % [meth, location, loc]
      }.compact

      next if bad.empty?

      io.puts
      io.puts klass
      io.puts bad.join "\n"
    end
    io.puts
    io.puts "Total suspect LOC: %d" % [total]
  end

  def report_json io, focus, missing
    require "json"

    data = {
      :missing => missing
    }

    data[:focus] = focus if focus

    JSON.dump data, io
  end

  def report_yaml io, focus, missing
    require "yaml"

    data = {
      :missing => missing
    }

    data[:focus] = focus if focus

    YAML.dump data, io
  end

  ##
  # Rails' macro-style methods that setup method calls to happen during a rails
  # app's execution.

  RAILS_DSL_METHODS = [
    :after_action,
    :around_action,
    :before_action,

    # http://api.rubyonrails.org/classes/ActiveRecord/Callbacks.html
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

  ##
  # Rails' macro-style methods that count as method calls if their options
  # include +:if+ or +:unless+.

  RAILS_VALIDATION_METHODS = [
    # http://api.rubyonrails.org/classes/ActiveModel/Validations/HelperMethods.html
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

  ##
  # Rails' macro-style methods that define methods dynamically.

  RAILS_MACRO_METHODS = [
    :belongs_to,
    :has_and_belongs_to_many,
    :has_many,
    :has_one,
    :scope,
  ]

  ##
  # GraphQL defining a field means that a method is used to resolve a field in the schema.

  GRAPHQL_OBJECT_METHODS = [
    :field,
  ]
end
