require "minitest/autorun"
require "debride"

class TestDebride < Minitest::Test
  def test_sanity
    debride = nil

    assert_silent do
      debride = Debride.run %w[lib]
    end

    exp = [["Debride",
            [:process_call, :process_defn, :process_defs, :report, :run]]]

    assert_equal exp, debride.missing
  end

  def assert_option arg, rest, exp_opt
    opt = Debride.parse_options arg

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
    skip "not yet"

    assert_option %w[--exclude path], %w[], :exclude => "path"
  end
end
