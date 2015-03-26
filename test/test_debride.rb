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

  def test_parse_options_whitelist
    exp = File.readlines("Manifest.txt").map(&:chomp) # omg dumb
    assert_option %w[--whitelist Manifest.txt], %w[], :whitelist => exp
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
end
