#--
# Copyright (c) 2005-2009, John Mettraux, jmettraux@gmail.com
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# Made in Japan.
#++

require 'ruote/fei'


module Ruote

  VERSION = '2.1.0'

  class Worker

    EXP_ACTIONS = %w[ reply cancel fail receive ]
      # 'apply' is comprised in 'launch'
      # 'receive' is a ParticipantExpression alias for 'reply'

    PROC_ACTIONS = %w[ cancel_process kill_process ]

    attr_reader :storage
    attr_reader :context

    attr_reader :run_thread
    attr_reader :running

    def initialize (storage)

      @storage = storage

      @subscribers = []
      @context = Ruote::WorkerContext.new(self)

      @last_time = Time.at(0.0).utc # 1970...

      @running = true
      @run_thread = nil

      @msgs = []
      @sleep_time = 0.001
    end

    def run

      while(@running) do
        step
      end
    end

    def run_in_thread

      Thread.abort_on_exception = true
        # TODO : remove me at some point

      @running = true

      @run_thread = Thread.new { run }
    end

    def subscribe (actions, subscriber)

      @subscribers << [ actions, subscriber ]
    end

    def shutdown

      @running = false
      @run_thread.join if @run_thread
    end

    protected

    def step

      now = Time.now.utc
      delta = now - @last_time

      if delta >= 1.0
        #
        # at most once per second

        @last_time = now

        # at schedules

        @storage.get_ats(delta, now).each { |sche| trigger_at(sche) }

        # cron schedules

        @storage.get_crons(delta, now).each { |sche| trigger_cron(sche) }
      end

      # msgs

      @msgs = @storage.get_msgs if @msgs.empty?

      processed = 0
      collisions = 0

      while msg = @msgs.shift

        r = process(msg)

        if r != false
          processed += 1
        else
          collisions += 1
        end

        if collisions > 2
          @msgs = @msgs[(@msgs.size / 2)..-1] || []
        end

        #@msgs.concat(@storage.get_local_msgs)

        #print r == false ? '*' : '.'

        break if Time.now.utc - @last_time >= 1.0
      end

      #puts processed.to_s

      #sleep(0.100) if processed == 0
      if processed == 0
        @sleep_time += 0.001
        @sleep_time = 0.490 if @sleep_time > 0.490
        sleep(@sleep_time)
      else
        @sleep_time = 0.001
      end
    end

    def trigger_at (schedule)

      msg = schedule['msg']

      return false unless @storage.reserve(schedule)

      @storage.put_msg(msg.delete('action'), msg)

      true
    end

    def trigger_cron (schedule)

      # TODO : implement
    end

    def process (msg)

      return false if cannot_handle(msg)

      return false unless @storage.reserve(msg)

      fexp = nil

      begin

        action = msg['action']

        if msg['tree']
          #
          # warning here, it could be a reply, with a 'tree' key...

          launch(msg)

        elsif EXP_ACTIONS.include?(action)

          Ruote::Exp::FlowExpression.do_action(@context, msg)

        elsif action == 'dispatch'

          dispatch(msg)

        elsif PROC_ACTIONS.include?(action)

          self.send(action, msg)

        #else
          # msg got deleted, might still be interesting for a subscriber
        end

        notify(msg)

      rescue Exception => ex

        handle_exception(msg, fexp, ex)
      end

      true
    end

    def handle_exception (msg, fexp, ex)

      wfid = msg['wfid'] || (msg['fei']['wfid'] rescue nil)
      fei = msg['fei'] || (fexp.h.fei rescue nil)

      # debug only

      if ARGV.include?('-d')

        puts "\n== worker intercepted error =="
        puts
        p ex
        ex.backtrace[0, 10].each { |l| puts l }
        puts "..."
        puts
        puts "-- msg --"
        msg.keys.sort.each { |k|
          puts "    #{k.inspect} =>\n#{msg[k].inspect}"
        }
        puts "-- . --"
        puts
      end

      # on_error ?

      if not(fexp) && fei
        fexp = Ruote::Exp::FlowExpression.fetch(@context, fei)
      end

      return if fexp && fexp.handle_on_error

      # emit 'msg'

      @storage.put_msg(
        'error_intercepted',
        'message' => ex.inspect,
        'wfid' => wfid,
        'msg' => msg)

      # fill error in the error journal

      @storage.put(
        'type' => 'errors',
        '_id' => "err_#{Ruote.to_storage_id(fei)}",
        'message' => ex.inspect,
        'trace' => ex.backtrace.join("\n"),
        'msg' => msg
      ) if fei
    end

    def notify (msg)

      @subscribers.each do |actions, subscriber|

        if actions == :all || actions.include?(msg['action'])
          subscriber.notify(msg)
        end
      end
    end

    def cannot_handle (msg)

      return false if msg['action'] != 'dispatch'

      @context.engine.nil? && msg['for_engine_worker?']
    end

    def dispatch (msg)

      pname = msg['participant_name']

      participant = @context.plist.lookup(pname)

      participant.consume(Ruote::Workitem.new(msg['workitem']))
    end

    # Works for both the 'launch' and the 'apply' msgs.
    #
    def launch (msg)

      tree = msg['tree']
      variables = msg['variables']

      exp_class = @context.expmap.expression_class(tree.first)

      # msg['wfid'] only : it's a launch
      # msg['fei'] : it's a sub launch (a supplant ?)

      exp_hash = {
        'fei' => msg['fei'] || {
          'engine_id' => @context['engine_id'] || 'engine',
          'wfid' => msg['wfid'],
          'expid' => '0' },
        'parent_id' => msg['parent_id'],
        'original_tree' => tree,
        'variables' => variables,
        'applied_workitem' => msg['workitem'],
        'forgotten' => msg['forgotten']
      }

      if not exp_class

        exp_class, tree = lookup_subprocess_or_participant(exp_hash)

      elsif msg['action'] == 'launch' && exp_class == Ruote::Exp::DefineExpression
        def_name, tree = Ruote::Exp::DefineExpression.reorganize(tree)
        variables[def_name] = [ '0', tree ] if def_name
        exp_class = Ruote::Exp::SequenceExpression
      end

      raise_unknown_expression_error(exp_hash) unless exp_class

      exp = exp_class.new(@context, exp_hash.merge!('original_tree' => tree))
      exp.initial_persist
      exp.do_apply
    end

    def raise_unknown_expression_error (exp_hash)

      exp_hash['state'] = 'failed'
      exp_hash['has_error'] = true

      Ruote::Exp::RawExpression.new(@context, exp_hash).persist
        # undigested expression is stored

      raise "unknown expression '#{exp_hash['original_tree'].first}'"
    end

    def lookup_subprocess_or_participant (exp_hash)

      tree = exp_hash['original_tree']

      key, value = Ruote::Exp::FlowExpression.new(
        @context, exp_hash.merge('name' => 'temporary')
      ).iterative_var_lookup(tree[0])

      sub = value
      part = @context.plist.lookup_info(key)

      sub = key if (not sub) && (not part) && Ruote.is_uri?(key)
        # for when a variable points to the URI of a[n external] subprocess

      if sub or part

        tree[1]['ref'] = key
        tree[1]['original_ref'] = tree[0] if key != tree[0]

        tree[0] = sub ? 'subprocess' : 'participant'

        [ sub ?
            Ruote::Exp::SubprocessExpression :
            Ruote::Exp::ParticipantExpression,
          tree ]
      else

        [ nil, tree ]
      end
    end

    def cancel_process (msg)

      root = @storage.find_root_expression(msg['wfid'])

      return unless root

      flavour = (msg['action'] == 'kill_process') ? 'kill' : nil

      @storage.put_msg(
        'cancel',
        'fei' => root['fei'],
        'wfid' => msg['wfid'], # indicates this was triggered by cancel_process
        'flavour' => flavour)
    end

    alias :kill_process :cancel_process
  end
end
