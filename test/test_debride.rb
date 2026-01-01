require "minitest/autorun"
require "debride"

$: << "../../debride-erb/dev/tmp/isolate"

class SafeDebride < Debride
  def self.abort s
    raise s
  end
end

class TestDebride < Minitest::Test
  EXP_LIST = [["Debride",
               [:process_alias,
                :process_attrasgn,
                :process_block_pass,
                :process_cdecl,
                :process_colon2,
                :process_colon3,
                :process_const,
                :process_defn,
                :process_defs,
                :process_hash,
                :process_op_asgn2,
                :process_rb,
                :process_safe_call,
                :report,
                :report_json,
                :report_text,
                :report_yaml]]]

  formatted_vals = EXP_LIST.map { |k,vs|
    [k, vs.map { |v| [v, "lib/debride.rb:###"] } ]
  }.to_h

  EXP_FORMATTED = { :missing => formatted_vals }

  make_my_diffs_pretty!

  def assert_option arg, exp_arg, exp_opt
    opt = SafeDebride.parse_options arg

    wl = [:extended, :included, :inherited, :method_added, :method_missing, :prepended]

    exp_opt = {:whitelist => wl, :exclude => [], :format => :text}.merge exp_opt
    assert_equal exp_opt, opt
    assert_equal exp_arg, arg
  end

  def assert_process exp, ruby, called:nil, **opts
    io = StringIO.new ruby

    debride = Debride.new opts
    debride.process debride.process_rb io

    assert_equal exp, debride.missing
    assert_equal Set[*called], debride.called if called

    debride
  end

  def test_sanity
    debride = nil

    assert_silent do
      debride = Debride.run %w[lib]
    end

    assert_equal EXP_LIST, debride.missing
  end

  def test_parse_options
    assert_option %w[--verbose woot.rb], %w[woot.rb], :verbose => true
    assert_option %w[-v woot.rb],        %w[woot.rb], :verbose => true
  end

  def test_parse_options_empty
    e = assert_raises RuntimeError do
      assert_option %w[], %w[], {}
    end

    assert_includes e.message, "debride [options] files_or_dirs"

    e = assert_raises RuntimeError do
      assert_option %w[-v], %w[], :verbose => true
    end

    assert_includes e.message, "debride [options] files_or_dirs"
  end

  def test_parse_options_exclude
    assert_option %w[--exclude moot.rb lib], %w[lib], :exclude => %w[moot.rb]
    assert_option %w[-e moot lib],           %w[lib], :exclude => %w[moot]
    assert_option %w[-e moot,moot.rb lib],   %w[lib], :exclude => %w[moot moot.rb]
  end

  def test_parse_options_focus
    assert_option %w[-f lib lib], %w[lib], :focus => "lib/*"
    assert_option %w[--focus lib lib], %w[lib], :focus => "lib/*"

    e = assert_raises RuntimeError do
      assert_option %w[-f missing lib], %w[], :verbose => true
    end

    assert_includes e.message, "ERROR: --focus path missing doesn't exist."
  end

  def test_parse_options_whitelist
    exp = File.readlines("Manifest.txt").map(&:chomp) # omg dumb
    assert_option %w[--whitelist Manifest.txt lib], %w[lib], :whitelist => exp
  end

  def test_exclude_files
    debride = Debride.run %w[--exclude test/ lib test]

    assert_equal EXP_LIST, debride.missing
  end

  def test_exclude_files__multiple
    debride = Debride.run %w[--exclude test,lib lib test]

    assert_empty debride.missing
  end

  def test_exclude_files__dir_without_slash
    debride = Debride.run %w[--exclude test lib test]

    assert_equal EXP_LIST, debride.missing
  end

  def test_focus
    debride = Debride.run %w[--focus lib/debride.rb lib test]
    io      = StringIO.new

    debride.report(io)

    assert_includes io.string, "Focusing on lib/debride.rb"
  end

  def test_format__plain
    debride = Debride.run %w[lib]
    io      = StringIO.new

    debride.report(io)

    assert_match %r%process_attrasgn\s+lib/debride.rb:\d+-\d+%, io.string
  end

  def test_format__json
    debride = Debride.run %w[lib --json]
    io      = StringIO.new

    debride.report(io)

    exp  = JSON.load JSON.dump EXP_FORMATTED # force stringify
    data = JSON.load io.string.gsub(/:\d+(-\d+)?/, ":###")

    assert_equal exp, data
  end

  def test_format__yaml
    debride = Debride.run %w[lib --yaml]
    io      = StringIO.new

    debride.report(io)

    exp  = EXP_FORMATTED
    data = YAML.load io.string.gsub(/:\d+(-\d+)?/, ":###")

    assert_equal exp, data
  end

  def test_whitelist
    ruby = <<-RUBY
      class Seattle
        def self.raining?
          true
        end
      end

      # Seattle.raining?
    RUBY

    exp = [["Seattle", [:raining?]]]
    assert_process exp, ruby

    exp = []
    assert_process exp, ruby, :whitelist => %w[raining?]
  end

  def test_whitelist_regexp
    ruby = <<-RUBY
      class Seattle
        def self.raining?
          true
        end
      end

      # Seattle.raining?
    RUBY

    exp = [["Seattle", [:raining?]]]
    assert_process exp, ruby

    exp = []
    assert_process exp, ruby, :whitelist => %w[/raining/]
  end

  def test_process_rb_path
    file = Tempfile.new ["debride_test", ".rb"]

    file.write <<-RUBY.strip
      class Seattle
        def self.raining?
          true
        end
      end

      Seattle.raining?
    RUBY

    file.flush

    debride = Debride.new
    debride.process_rb file.path

    exp = []

    assert_equal exp, debride.missing
  end

  def test_process_rb_io
    s = <<-RUBY.strip
      class Seattle
        def self.raining?
          true
        end
      end

      Seattle.raining?
    RUBY

    assert_process [], s
  end

  def test_call__alias_method__symbol
    ruby = <<~'RUBY'
      class QuarterPounder
        alias_method :get_x, :x
      end
    RUBY

    exp = [["QuarterPounder", [:get_x]]]

    assert_process exp, ruby, called:%i[x alias_method]
  end

  def test_call__alias_method__string
    ruby = <<~'RUBY'
      class QuarterPounder
        alias_method "get_x", "x"
      end
    RUBY

    exp = [["QuarterPounder", [:get_x]]]

    assert_process exp, ruby, called:%i[x alias_method]
  end

  def test_call__alias_method__interpolated
    ruby = <<~'RUBY'
      class QuarterPounder
        alias_method "get_#{integr}", integr
      end
    RUBY

    assert_process [], ruby, called:%i[integr alias_method]
  end

  def test_alias_method_chain
    ruby = <<-RUBY.strip
      class QuarterPounder
        def royale_with_cheese
          1+1
        end

        alias_method_chain :royale, :cheese
      end
    RUBY

    exp = [["QuarterPounder", [:royale, :royale_with_cheese]]]

    assert_process exp, ruby, :rails => true
  end

  def test_cdecl_const2
    ruby = <<-RUBY.strip
      class Z
        X::Y = 42
      end
    RUBY

    assert_process [["Z", ["X::Y"]]], ruby
  end

  def test_cdecl_const3
    ruby = <<-RUBY.strip
      class Z
        ::Y = 42
      end
    RUBY

    assert_process [["Z", ["::Y"]]], ruby
  end

  def test_method_send
    ruby = <<-RUBY.strip
      class Seattle
        def self.raining?
          true
        end

        def self.coffee
          :good
        end
      end

      Seattle.send :raining?
      Seattle.__send__ "coffee"
      Seattle.send "\#{foo}_bar"
    RUBY

    assert_process [], ruby
  end

  def test_method_try
    ruby = <<-RUBY.strip
      class Seattle
        def self.raining?
          true
        end
      end

      Seattle.try :raining?
    RUBY

    assert_process [], ruby
  end

  def test_block_pass
    ruby = <<-RUBY.strip
      class Seattle
        def self.raining?
          true
        end
      end

      [Seattle].each(&:raining?)
    RUBY

    assert_process [], ruby
  end

  def test_block_pass_other
    ruby = <<-RUBY.strip
      class Seattle
        def self.raining?
          -> { called }
        end

        def self.uncalled; end
        def self.called; end
      end

      f(&Seattle.raining?)
    RUBY

    assert_process [["Seattle", [:uncalled]]], ruby
  end

  def test_block_pass_empty
    ruby = <<~RUBY
      def g(&)
        f(&) # block forwarding
      end
      g
    RUBY

    assert_process [], ruby
  end

  def test_hash__shorthand
    ruby = <<-RUBY.strip
      class Seattle
        def self.status
          { raining: }
        end

        def self.raining
          true
        end
      end

      Seattle.status
    RUBY

    assert_process [], ruby
  end

  def test_hash__not_shorthand
    ruby = <<-RUBY.strip
      class Seattle
        def self.status
          { missing: }
        end

        def self.raining
          true
        end
      end

      Seattle.status
    RUBY

    assert_process [["Seattle", [:raining]]], ruby
  end

  def test_safe_navigation_operator
    ruby = <<-RUBY.strip
      class Seattle
        def self.raining?
          true
        end
      end

      Seattle&.raining?
    RUBY

    assert_process [], ruby
  end

  def test_call_method
    ruby = <<-RUBY.strip
      class Seattle
        def self.raining?
          true
        end

        def self.raining_still?
          method(:raining?)
        end
      end

      Seattle.raining_still?
    RUBY

    assert_process [], ruby
  end

  def test_rails_dsl_methods
    ruby = <<-RUBY.strip
      class RailsThing
        def save_callback         ; 1 ; end
        def action_filter         ; 1 ; end
        def callback_condition    ; 1 ; end
        def action_condition      ; 1 ; end
        def string_condition      ; 1 ; end
        def validation_condition  ; 1 ; end
        def some_validation_method; 1 ; end

        before_save :save_callback, unless: :callback_condition
        before_save :save_callback, if: 'string_condition'
        before_action :action_filter, if: :action_condition, only: :new
        after_save :save_callback, if: lambda {|r| true }
        validates :database_column, if: :validation_condition
        validate :some_validation_method

        before_save do
          foo.bar
        end
      end
    RUBY

    assert_process [], ruby, :rails => true
  end

  def test_rails_dsl_macro_definitions
    ruby = <<~'RUBY'
      class RailsModel
        has_one :has_one_relation
        has_one :uncalled_has_one_relation
        belongs_to :belongs_to_relation
        belongs_to :uncalled_belongs_to_relation
        has_many :has_many_relation
        has_many :uncalled_has_many_relation
        has_and_belongs_to_many :has_and_belongs_to_many_relation
        has_and_belongs_to_many :uncalled_has_and_belongs_to_many_relation
        scope :scope_method
        scope :uncalled_scope_method
        scope :"interpolated_#{method}"
        scope "another_#{method}"
        scope "yet_another_#{method}".to_sym

        def instance_method_caller
          has_one_relation
          belongs_to_relation
          has_many_relation
          has_and_belongs_to_many_relation
        end

        def self.class_method_caller
          scope_method
        end

        class_method_caller
        new.instance_method_caller
      end
    RUBY

    unused_methods = [
      :uncalled_belongs_to_relation,
      :uncalled_has_and_belongs_to_many_relation,
      :uncalled_has_many_relation,
      :uncalled_has_one_relation,
      :uncalled_scope_method,
    ]

    assert_process [["RailsModel", unused_methods]], ruby, :rails => true
  end

  def test_constants
    ruby = <<-RUBY.strip
      class Constants
        USED = 42
        ALSO = 314
        AGAIN = 27
        MORE = 72
        UNUSED = 24

        def something
          p USED
        end
      end

      something
      Constants::ALSO
      ::Constants::ALSO
      Constants.const_get(:AGAIN)
      ::Constants.const_get("MORE")
    RUBY

    assert_process [["Constants", [:UNUSED]]], ruby
  end

  def test_attr_accessor
    ruby = <<-RUBY.strip
      class AttributeAccessor
        attr_accessor :a1, :a2, :a3
        attr_writer :w1, :w2, :w3, :w4
        attr_reader :r1, :r2
        def initialize
          self.a2 = 'Bar'
          self.w1 = 'W'
          self.w3 ||= 'W3'
          self.w4 &&= 'W4'
        end

        def self.class_method
          puts "bazinga"
        end
      end

      object = AttributeAccessor.new
      object.a1
      object.r1
      object.a3 = 'Baz'
    RUBY

    exp = [["AttributeAccessor",
            [:a1=, :a2, :a3, :class_method, :r2, :w2=]]]

    d = assert_process exp, ruby

    exp = {
           "AttributeAccessor#a1"         => "(io):2",
           "AttributeAccessor#a1="        => "(io):2",
           "AttributeAccessor#a2"         => "(io):2",
           "AttributeAccessor#a2="        => "(io):2",
           "AttributeAccessor#a3"         => "(io):2",
           "AttributeAccessor#a3="        => "(io):2",
           "AttributeAccessor#w1="        => "(io):3",
           "AttributeAccessor#w2="        => "(io):3",
           "AttributeAccessor#w3="        => "(io):3",
           "AttributeAccessor#w4="        => "(io):3",
           "AttributeAccessor#r1"         => "(io):4",
           "AttributeAccessor#r2"         => "(io):4",
           "AttributeAccessor#initialize" => "(io):5-10",
           "AttributeAccessor::class_method" => "(io):12-14"
          }

    assert_equal exp, d.method_locations

    out, err = capture_io do
      d.report
    end

    assert_match(/AttributeAccessor/, out)
    assert_match(/a1=/, out)
    assert_empty err
  end

  def test_attr_accessor_with_hash_default_value
    ruby = <<-RUBY.strip
      class AttributeAccessor
        attr_accessor :a1
        def initialize(options = {})
          self.a1 = options.fetch(:a1) { default_a1 }
        end

        def default_a1
          'the default_a1'
        end
      end

      object = AttributeAccessor.new
    RUBY

    assert_process [["AttributeAccessor", [:a1]]], ruby
  end
end
