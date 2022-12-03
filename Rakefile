# -*- ruby -*-

require "rubygems"
require "hoe"

Hoe::add_include_dirs("../../sexp_processor/dev/lib",
                      "../../ruby_parser/dev/lib",
                      "../../ruby2ruby/dev/lib",
                      "../../ZenTest/dev/lib",
                      "../../path_expander/dev/lib",
                      "lib")

Hoe.plugin :isolate
Hoe.plugin :seattlerb
Hoe.plugin :rdoc
Hoe.plugin :cov

Hoe.spec "debride" do
  developer "Ryan Davis", "ryand-ruby@zenspider.com"
  license "MIT"

  dependency "sexp_processor", "~> 4.5"
  dependency "ruby_parser", "~> 3.6"
  dependency "path_expander",  "~> 1.0"
end

def run dir, whitelist
  abort "Specify dir to scan with D=<path>" unless dir

  ENV["GEM_HOME"] = "tmp/isolate"
  ENV["GEM_PATH"] = "../../debride-erb/dev/tmp/isolate"

  whitelist = whitelist && ["--whitelist", whitelist]
  verbose   = ENV["V"]  && "-v"
  exclude   = ENV["E"]  && ["--exclude", ENV["E"]]
  minimum   = ENV["M"]  && ["--minimum", ENV["M"]]

  require "debride"

  args = ["--rails", verbose, minimum, whitelist, exclude, dir].flatten.compact

  Debride.run(args).report
end

task :run => :isolate do
  run ENV["D"], ENV["W"]
end

task :rails => :isolate do
  ENV["GEM_HOME"] = "tmp/isolate/ruby-2.0.0"
  ENV["GEM_PATH"] = "../../debride-erb/dev/tmp/isolate/ruby-2.0.0"

  d = File.expand_path "~/Work/git/seattlerb.org"

  run d, "#{d}/whitelist.txt"
end

task :debug do
  f = ENV["F"]
  run f, nil
end

# vim: syntax=ruby
