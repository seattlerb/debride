#!/usr/bin/ruby -w

$:.unshift "../../sexp_processor/dev/lib"

require "ruby_parser"
require "sexp_processor"
require "set"

class Debride < MethodBasedSexpProcessor
  VERSION = "1.0.0"

  def self.run args
    callers = Debride.new

    expand_dirs_to_files(args).each do |path|
      warn "processing: #{path}"
      parser = RubyParser.new
      callers.process parser.process File.read(path), path
    end

    callers
  end

  attr_accessor :known, :called
  attr_accessor :map # TODO: retire and use method_locations

  def initialize
    self.known  = Hash.new { |h,k| h[k] = Set.new }
    self.called = Set.new
    self.map    = Hash.new { |h,k| h[k] = {} }
    super
  end

  def process_defn sexp
    super do
      method_name = self.method_name[1..-1].to_sym
      map[klass_name][method_name] = signature
      known[method_name] << klass_name
      process_until_empty sexp
    end
  end

  def process_defs sexp
    super do
      method_name = self.method_name[2..-1].to_sym
      map[klass_name][method_name] = signature
      known[method_name] << klass_name
      process_until_empty sexp
    end
  end

  def process_call sexp
    method_name = sexp[2]
    method_name = :initialize if method_name == :new

    if method_name == :alias_method_chain
      known[sexp[3]] << klass_name
    end

    called << method_name

    process_until_empty sexp

    sexp
  end

  def missing
    not_called = known.keys - called.to_a

    by_class = Hash.new { |h,k| h[k] = [] }

    not_called.each do |meth|
      known[meth].each do |klass|
        by_class[klass] << meth
      end
    end

    by_class.each do |klass, meths|
      by_class[klass] = meths.sort
    end

    by_class.sort
  end

  def report
    puts "These methods MIGHT not be called:"

    missing.each do |klass, meths|
      puts
      puts klass
      meths.each do |meth|
        puts "  %-35s %s" % [meth, method_locations[map[klass][meth]]]
      end
    end
  end
end
