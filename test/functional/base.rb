
#
# testing ruote
#
# Sat Sep 20 23:40:10 JST 2008
#

require 'fileutils'

require File.join(File.dirname(__FILE__), '..', 'test_helper.rb')
require File.join(File.dirname(__FILE__), 'storage_helper.rb')

require 'ruote'


trap 'USR2' do

  require 'irb'
  require 'irb/completion'

  IRB.setup(nil)
  ws = IRB::WorkSpace.new(binding)
  irb = IRB::Irb.new(ws)
  IRB::conf[:MAIN_CONTEXT] = irb.context
  irb.eval_input
end

trap 'INT' do
  #
  # why do I have to do that ?
  #
  puts
  puts '-' * 80
  caller.each { |l| p l }
  puts '-' * 80
  exit 1
end if RUBY_VERSION.match(/^1.9./)

puts "pid #{$$}"


module FunctionalBase

  def setup

    p self.class if ARGV.include?('-T') or ARGV.include?('-N')

    #require 'ruote/util/look'
    #Ruote::Look.dump_lsof
    #Ruote::Look.dump_lsof_count
      #
      # uncomment this when "too many open files"

    @engine =
      Ruote::Engine.new(
        Ruote::Worker.new(
          determine_storage(
            's_logger' => [ 'ruote/log/test_logger', 'Ruote::TestLogger' ])))

    $_test = self
    $_engine = @engine
      #
      # handy when hijacking (https://github.com/ileitch/hijack)
      # or flinging USR2 at the test process

    @tracer = Tracer.new

    tracer = @tracer
    @engine.context.instance_eval { @tracer = tracer }

    @engine.add_service('tracer', @tracer)
    @engine.add_service('stash', {})

    noisy if ARGV.include?('-N')

    #noisy # uncommented, it makes all the tests noisy
  end

  def teardown

    @engine.shutdown
    @engine.context.storage.purge!
    @engine.context.storage.close if @engine.context.storage.respond_to?(:close)
  end

  def stash

    @engine.context.stash
  end

  def assert_log_count(count, &block)

    c = @engine.context.logger.log.select(&block).size

    #logger.to_stdout if ( ! @engine.context[:noisy]) && c != count

    assert_equal count, c
  end

  #   assert_trace(*expected_traces, pdef)
  #   assert_trace(*expected_traces, fields, pdef)
  #
  def assert_trace(*args)

    if args.last == :clear
      args.pop
      @tracer.clear
    end

    pdef = args.pop
    fields = args.last.is_a?(Hash) ? args.pop : {}
    expected_traces = args.collect { |et| et.is_a?(Array) ? et.join("\n") : et }

    wfid = @engine.launch(pdef, fields)

    r = wait_for(wfid)

    assert_engine_clean(wfid)

    trace = r['workitem']['fields']['_trace']
    trace = trace ? trace.join('') : @tracer.to_s

    if expected_traces.length > 0
      ok, nok = expected_traces.partition { |et| trace == et }
      assert_equal(nok.first, trace) if ok.empty?
    end

    assert(true)
      # so that the assertion count matches

    wfid
  end

  def logger

    @engine.context.logger
  end

  protected

  def noisy(on=true)

    puts "\nnoisy " + caller[0] if on
    @engine.context.logger.noisy = true
  end

  def wait_for(*wfid_or_part)

    @engine.wait_for(*wfid_or_part)
  end

  def assert_engine_clean(wfid)

    assert_no_errors(wfid)
    assert_no_remaining_expressions(wfid)
  end

  def assert_no_errors(wfid)

    errors = @engine.storage.get_many('errors', /#{wfid}$/)

    return if errors.size == 0

    puts
    puts '-' * 80
    puts 'remaining process error(s)'
    puts
    errors.each do |e|
      puts "  ** #{e['message']}"
      puts e['trace']
    end
    puts '-' * 80

    puts_trace_so_far

    flunk 'remaining process error(s)'
  end

  def assert_no_remaining_expressions(wfid)

    expcount = @engine.storage.get_many('expressions').size
    return if expcount == 0

    tf, _, tn = caller[2].split(':')

    puts
    puts '-' * 80
    puts 'too many expressions left in storage'
    puts
    puts "this test : #{tf}"
    puts "            #{tn}"
    puts
    puts "this test's wfid : #{wfid}"
    puts
    puts 'left :'
    puts
    puts @engine.context.storage.dump('expressions')
    puts
    puts '-' * 80

    puts_trace_so_far

    flunk 'too many expressions left in storage'
  end

  def puts_trace_so_far

    #puts '. ' * 40
    puts 'trace so far'
    puts '---8<---'
    puts @tracer.to_s
    puts '--->8---'
    puts
  end
end

# Re-opening workitem for a shortcut to a '_trace' field
#
class Ruote::Workitem
  def trace
    @h['fields']['_trace'] ||= []
  end
end

class Tracer
  attr_reader :s
  def initialize
    super
    @s = ''
  end
  def to_s
    @s.to_s.strip
  end
  def to_a
    to_s.split("\n")
  end
  def << s
    @s << s
  end
  def clear
    @s = ''
  end
  def puts(s)
    @s << "#{s}\n"
  end
end

