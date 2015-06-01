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
  end

  def test_sanity
    skip "This is slow" unless ENV["SLOW"]

    debride = nil

    assert_silent do
      debride = Debride.run %w[lib]
    end

    exp = [["Debride",
            [:process_call, :process_defn, :process_defs, :process_rb, :report]]]

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
            [:process_call, :process_defn, :process_defs, :process_rb, :report]]]

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

        before_save :save_callback, unless: :callback_condition
        before_save :save_callback, if: 'string_condition'
        before_action :action_filter, if: :action_condition, only: :new
        after_save :save_callback, if: lambda {|r| true }
        validates :database_column, if: :validation_condition
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
end
