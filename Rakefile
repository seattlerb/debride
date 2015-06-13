# -*- ruby -*-

require "rubygems"
require "hoe"

Hoe.plugin :isolate
Hoe.plugin :seattlerb
Hoe.plugin :rdoc

Hoe.spec "debride" do
  developer "Ryan Davis", "ryand-ruby@zenspider.com"
  license "MIT"

  dependency "sexp_processor", "~> 4.5"
  dependency "ruby_parser", "~> 3.6"
end

def run dir, wl
  ENV["GEM_HOME"] = "tmp/isolate/ruby-2.0.0"
  ENV["GEM_PATH"] = "../../debride-erb/dev/tmp/isolate/ruby-2.0.0"

  abort "Specify dir to scan with D=<path>" unless dir
  wl = "--whitelist #{wl}" if wl

  ruby "-Ilib:../../debride-erb/dev/lib bin/debride -v --rails #{dir} #{wl}"
end

task :run do
  run ENV["D"], ENV["W"]
end

task :rails do
  d = "~/Work/git/seattlerb.org"
  run "#{d}/{app,lib,config}", "#{d}/whitelist.txt"
end

task :debug do
  f = ENV["F"]
  run f, nil
end

# vim: syntax=ruby
