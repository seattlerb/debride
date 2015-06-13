require "minitest/autorun"
require "debride"

class SafeDebride < Debride
  def self.abort s
    raise s
  end
end

class TestDebride < Minitest::Test
  def assert_option arg, exp_arg, exp_opt
    opt = SafeDebride.parse_options arg

    exp_opt = {:whitelist => []}.merge exp_opt
    assert_equal exp_opt, opt
    assert_equal exp_arg, arg
  end

  def assert_process exp, ruby, opts = {}
    io = StringIO.new ruby

    debride = Debride.new opts
    debride.process debride.process_rb io

    assert_equal exp, debride.missing
    debride
  end

  def test_sanity
    skip "This is slow" unless ENV["SLOW"]

    debride = nil

    assert_silent do
      debride = Debride.run %w[lib]
    end

    exp = [["Debride",
            [:process_attrasgn, :process_call, :process_cdecl, :process_colon2,
             :process_colon3, :process_const, :process_defn, :process_defs,
             :process_rb, :report]]]

    assert_equal exp, debride.missing
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
    skip "This is slow" unless ENV["SLOW"]

    debride = Debride.run %w[--exclude test lib]

    exp = [["Debride",
            [:process_attrasgn, :process_call, :process_cdecl, :process_colon2,
             :process_colon3, :process_const, :process_defn, :process_defs,
             :process_rb, :report]]]

    assert_equal exp, debride.missing
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
      end
    RUBY

    assert_process [], ruby, :rails => true
  end

  def test_constants
    ruby = <<-RUBY.strip
      class Constants
        USED = 42
        ALSO = 314
        UNUSED = 24

        def something
          p USED
        end
      end

      something
      Constants::ALSO
      ::Constants::ALSO
    RUBY

    assert_process [["Constants", [:UNUSED]]], ruby
  end

  def test_attr_accessor
    ruby = <<-RUBY.strip
      class AttributeAccessor
        attr_accessor :a1, :a2, :a3
        attr_writer :w1, :w2
        attr_reader :r1, :r2
        def initialize
          self.a2 = 'Bar'
          self.w1 = 'W'
        end
      end

      object = AttributeAccessor.new
      object.a1
      object.r1
      object.a3 = 'Baz'
    RUBY

    d = assert_process [["AttributeAccessor", [:a1=, :a2, :a3, :r2, :w2=]]], ruby

    exp = {
           "AttributeAccessor" => {
                                   :a1         => "AttributeAccessor#a1",
                                   :a1=        => "AttributeAccessor#a1=",
                                   :a2         => "AttributeAccessor#a2",
                                   :a2=        => "AttributeAccessor#a2=",
                                   :a3         => "AttributeAccessor#a3",
                                   :a3=        => "AttributeAccessor#a3=",
                                   :w1=        => "AttributeAccessor#w1=",
                                   :w2=        => "AttributeAccessor#w2=",
                                   :r1         => "AttributeAccessor#r1",
                                   :r2         => "AttributeAccessor#r2",
                                   :initialize => "AttributeAccessor#initialize"
                                  }
          }

    assert_equal exp, d.map

    exp = {
           "AttributeAccessor#a1"         => "(io):2",
           "AttributeAccessor#a1="        => "(io):2",
           "AttributeAccessor#a2"         => "(io):2",
           "AttributeAccessor#a2="        => "(io):2",
           "AttributeAccessor#a3"         => "(io):2",
           "AttributeAccessor#a3="        => "(io):2",
           "AttributeAccessor#w1="        => "(io):3",
           "AttributeAccessor#w2="        => "(io):3",
           "AttributeAccessor#r1"         => "(io):4",
           "AttributeAccessor#r2"         => "(io):4",
           "AttributeAccessor#initialize" => "(io):5",
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
