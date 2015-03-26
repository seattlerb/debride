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

task :rails do
  ENV["GEM_HOME"] = "tmp/isolate/ruby-2.0.0"
  ENV["GEM_PATH"] = "../../debride-erb/dev/tmp/isolate/ruby-2.0.0"
  ruby "-Ilib:../../debride-erb/dev/lib bin/debride ~/Work/git/seattlerb.org/{app,lib} --whitelist ~/Work/git/seattlerb.org/whitelist.txt"
end

# vim: syntax=ruby
