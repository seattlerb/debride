require "minitest/autorun"
require "debride"

class TestDebride < Minitest::Test
  def test_sanity
    debride = nil

    assert_output "", "processing: lib/debride.rb\n" do
      debride = Debride.run "lib"
    end

    exp = [["Debride",
            [:process_call, :process_defn, :process_defs, :report, :run]]]

    assert_equal exp, debride.missing
  end
end
