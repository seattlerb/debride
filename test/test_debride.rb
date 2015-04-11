require "minitest/autorun"
require "debride"

class TestDebride < Minitest::Test
  def test_sanity
    debride = nil

    assert_silent do
      debride = Debride.run %w[lib]
    end

    exp = [["Debride",
            [:process_call, :process_defn, :process_defs, :process_rb, :report]]]

    assert_equal exp, debride.missing
  end

  def assert_option arg, rest, exp_opt
    opt = Debride.parse_options arg

    exp_opt = {:whitelist => []}.merge exp_opt
    assert_equal exp_opt, opt
    assert_equal rest, arg
  end

  def test_parse_options
    assert_option %w[], %w[], {}

    assert_option %w[--verbose],  %w[],        :verbose => true
    assert_option %w[-v],         %w[],        :verbose => true
    assert_option %w[-v woot.rb], %w[woot.rb], :verbose => true
  end

  def test_parse_options_exclude
    assert_option %w[--exclude moot.rb],   %w[],    :exclude => %w[moot.rb]
    assert_option %w[-e moot lib],         %w[lib], :exclude => %w[moot]
    assert_option %w[-e moot,moot.rb lib], %w[lib], :exclude => %w[moot moot.rb]
  end

  def test_parse_options_whitelist
    exp = File.readlines("Manifest.txt").map(&:chomp) # omg dumb
    assert_option %w[--whitelist Manifest.txt], %w[], :whitelist => exp
  end

  def test_exclude_files
    debride = Debride.run %w[--exclude test lib]

    exp = [["Debride",
            [:process_call, :process_defn, :process_defs, :process_rb, :report]]]

    assert_equal exp, debride.missing
  end

  def test_whitelist
    debride = Debride.run %w[lib]
    debride.option[:whitelist] = %w[process_defn]

    exp = [["Debride",
            [:process_call, :process_defs, :process_rb, :report]]]

    assert_equal exp, debride.missing
  end

  def test_whitelist_regexp
    debride = Debride.run %w[lib]
    debride.option[:whitelist] = %w[/^process_/ run]

    exp = [["Debride", [:report]]]

    assert_equal exp, debride.missing
  end

  def test_alias_method_chain
    file = Tempfile.new ["debride_test", ".rb"]

    file.write <<-RUBY.strip
      class QuarterPounder
        def royale_with_cheese
          1+1
        end

        alias_method_chain :royale, :cheese
      end
    RUBY

    file.flush

    debride = Debride.run [file.path, "--rails"]

    exp = [["QuarterPounder", [:royale, :royale_with_cheese]]]

    assert_equal exp, debride.missing
  end

  def test_method_send
    file = Tempfile.new ["debride_test", ".rb"]

    file.write <<-RUBY.strip
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

    file.flush

    debride = Debride.run [file.path]

    exp = []

    assert_equal exp, debride.missing
  end

  def test_rails_dsl_methods
    file = Tempfile.new ["debride_test", ".rb"]

    file.write <<-RUBY.strip
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

    file.flush

    debride = Debride.run [file.path, "--rails"]

    assert_equal [], debride.missing.sort
  end
end
