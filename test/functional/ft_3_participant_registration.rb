
#
# testing ruote
#
# Mon May 18 22:25:57 JST 2009
#

require File.join(File.dirname(__FILE__), 'base')

require 'ruote'


class FtParticipantRegistrationTest < Test::Unit::TestCase
  include FunctionalBase

  def test_participant_register

    #noisy

    @engine.register_participant :alpha do |workitem|
      @tracer << 'alpha'
    end
    @engine.register_participant /^user_/, Ruote::NullParticipant

    wait_for(2)

    assert_equal(
      'participant_registered',
      logger.log[0]['action'])

    assert_equal(
      %w[ alpha /^user_/ ],
      logger.log.collect { |msg| msg['regex'] })

    assert_equal(
      [ [ '^alpha$',
          [ 'Ruote::BlockParticipant',
            { 'on_workitem' => 'proc { |workitem| (@tracer << "alpha") }' } ] ],
        [ '^user_',
          [ 'Ruote::NullParticipant',
            {} ] ] ],
      @engine.participant_list.collect { |pe| pe.to_a })
  end

  def test_participant_register_position

    @engine.register_participant :ur, Ruote::StorageParticipant

    assert_equal(
      %w[ ^ur$ ],
      @engine.participant_list.collect { |pe| pe.regex.to_s })

    @engine.register_participant(
      :first, Ruote::StorageParticipant, :position => :first)
    @engine.register_participant(
      :last, Ruote::StorageParticipant, :position => :last)

    assert_equal(
      %w[ ^first$ ^ur$ ^last$ ],
      @engine.participant_list.collect { |pe| pe.regex.to_s })

    @engine.register_participant(
      :x, Ruote::StorageParticipant, :position => -2)

    assert_equal(
      %w[ ^first$ ^ur$ ^x$ ^last$ ],
      @engine.participant_list.collect { |pe| pe.regex.to_s })
  end

  def test_participant_register_before

    @engine.register_participant :alpha, 'AlphaParticipant'
    @engine.register_participant :bravo, 'BravoParticipant'
    @engine.register_participant :alpha, 'AlphaPrimeParticipant', :pos => :after

    assert_equal(
      [ %w[ ^alpha$ AlphaParticipant ],
        %w[ ^alpha$ AlphaPrimeParticipant ],
        %w[ ^bravo$ BravoParticipant ] ],
      @engine.participant_list.collect { |e| [ e.regex, e.classname ] })
  end

  def test_participant_register_after

    @engine.register_participant :alpha, 'AlphaParticipant'
    @engine.register_participant :alpha, 'AlphaPrimeParticipant', :pos => :before

    assert_equal(
      [ %w[ ^alpha$ AlphaPrimeParticipant ],
        %w[ ^alpha$ AlphaParticipant ] ],
      @engine.participant_list.collect { |e| [ e.regex, e.classname ] })
  end

  def test_participant_register_before_after_corner_cases

    @engine.register_participant :alpha, 'KlassA', :pos => :before
    @engine.register_participant :bravo, 'KlassB', :pos => :after

    assert_equal(
      [ %w[ ^alpha$ KlassA ],
        %w[ ^bravo$ KlassB ] ],
      @engine.participant_list.collect { |e| [ e.regex, e.classname ] })
  end

  def test_participant_register_over

    @engine.register_participant :alpha, 'KlassA'
    @engine.register_participant :bravo, 'KlassB'
    @engine.register_participant :alpha, 'KlassAa', :pos => :over
    @engine.register_participant :charly, 'KlassC', :pos => :over

    assert_equal(
      [ %w[ ^alpha$ KlassAa ],
        %w[ ^bravo$ KlassB ],
        %w[ ^charly$ KlassC ] ],
      @engine.participant_list.collect { |e| [ e.regex, e.classname ] })
  end

  def test_double_registration

    @engine.register_participant :alpha do |workitem|
      @tracer << 'alpha'
    end
    @engine.register_participant :alpha do |workitem|
      @tracer << 'alpha'
    end

    assert_equal 1, @engine.context.plist.send(:get_list)['list'].size
  end

  def test_register_and_return_something

    pa = @engine.register_participant :alpha do |workitem|
    end
    pb = @engine.register_participant :bravo, Ruote::StorageParticipant

    assert_nil pa
    assert_equal Ruote::StorageParticipant, pb.class
  end

  def test_participant_unregister_by_name

    #noisy

    @engine.register_participant :alpha do |workitem|
    end

    @engine.unregister_participant(:alpha)

    wait_for(2)
    Thread.pass

    msg = logger.log.last
    assert_equal 'participant_unregistered', msg['action']
    assert_equal '^alpha$', msg['regex']
  end

  def test_participant_unregister

    @engine.register_participant :alpha do |workitem|
    end

    @engine.unregister_participant('alpha')

    wait_for(2)

    msg = logger.log.last
    assert_equal 'participant_unregistered', msg['action']
    assert_equal '^alpha$', msg['regex']

    assert_equal 0, @engine.context.plist.list.size
  end

  class MyParticipant
    @@down = false
    def self.down
      @@down
    end
    def initialize
    end
    def shutdown
      @@down = true
    end
  end

  def test_participant_shutdown

    alpha = @engine.register :alpha, MyParticipant

    @engine.context.plist.shutdown

    assert_equal true, MyParticipant.down
  end

  def test_participant_list_of_names

    pa = @engine.register_participant :alpha do |workitem|
    end

    assert_equal [ '^alpha$' ], @engine.context.plist.names
  end

  def test_register_require_path

    rpath = File.join(
      File.dirname(__FILE__), "#{Time.now.to_f}_#{$$}_required_participant")
    path = "#{rpath}.rb"

    File.open(path, 'wb') do |f|
      f.write(%{
        class RequiredParticipant
          include Ruote::LocalParticipant
          def initialize(opts)
            @opts = opts
          end
          def consume(workitem)
            workitem.fields['message'] = @opts['message']
            reply(workitem)
          end
        end
      })
    end

    @engine.register_participant(
      :alfred,
      'RequiredParticipant',
      :require_path => rpath, :message => 'hello')

    assert_equal [ '^alfred$' ], @engine.context.plist.names

    # first run

    assert_equal(
      [ 'RequiredParticipant',
        { 'require_path' => rpath, 'message' => 'hello' } ],
      @engine.context.plist.lookup_info('alfred', nil))

    wfid = @engine.launch(Ruote.define { alfred })
    r = @engine.wait_for(wfid)

    assert_equal 'hello', r['workitem']['fields']['message']

    # second run

    File.open(path, 'wb') do |f|
      f.write(%{
        class RequiredParticipant
          include Ruote::LocalParticipant
          def initialize(opts)
            @opts = opts
          end
          def consume(workitem)
            workitem.fields['message'] = 'second run'
            reply(workitem)
          end
        end
      })
    end

    wfid = @engine.launch(Ruote.define { alfred })
    r = @engine.wait_for(wfid)

    # since it's a 'require', the code isn't reloaded

    assert_equal 'hello', r['workitem']['fields']['message']

    FileUtils.rm(path)
  end

  def test_reqister_load_path

    path = File.join(
      File.dirname(__FILE__), "#{Time.now.to_f}_#{$$}_loaded_participant.rb")

    File.open(path, 'wb') do |f|
      f.write(%{
        class LoadedParticipant
          include Ruote::LocalParticipant
          def initialize(opts)
            @opts = opts
          end
          def consume(workitem)
            workitem.fields['message'] = @opts['message']
            reply(workitem)
          end
        end
      })
    end

    @engine.register_participant(
      :alfred,
      'LoadedParticipant',
      :load_path => path, :message => 'bondzoi')

    assert_equal [ '^alfred$' ], @engine.context.plist.names

    # first run

    assert_equal(
      [ 'LoadedParticipant',
        { 'load_path' => path, 'message' => 'bondzoi' } ],
      @engine.context.plist.lookup_info('alfred', nil))

    wfid = @engine.launch(Ruote.define { alfred })
    r = @engine.wait_for(wfid)

    assert_equal 'bondzoi', r['workitem']['fields']['message']

    # second run

    File.open(path, 'wb') do |f|
      f.write(%{
        class LoadedParticipant
          include Ruote::LocalParticipant
          def initialize(opts)
            @opts = opts
          end
          def consume(workitem)
            workitem.fields['message'] = 'second run'
            reply(workitem)
          end
        end
      })
    end

    wfid = @engine.launch(Ruote.define { alfred })
    r = @engine.wait_for(wfid)

    # since it's a 'load', the code is reloaded

    assert_equal 'second run', r['workitem']['fields']['message']

    FileUtils.rm(path)
  end

  def test_participant_list

    #noisy

    @engine.register_participant 'alpha', Ruote::StorageParticipant

    assert_equal(
      [ '/^alpha$/ ==> Ruote::StorageParticipant {}' ],
      @engine.participant_list.collect { |pe| pe.to_s })

    # launching a process with a missing participant

    wfid = @engine.launch(Ruote.define { bravo })
    @engine.wait_for(wfid)

    assert_equal 1, @engine.process(wfid).errors.size

    # fixing the error by updating the participant list

    list = @engine.participant_list
    list.first.regex = '^.+$' # instead of '^alpha$'
    @engine.participant_list = list

    # replay at error

    @engine.replay_at_error(@engine.process(wfid).errors.first)
    @engine.wait_for(:bravo)

    # bravo should hold a workitem

    assert_equal 1, @engine.storage_participant.size
    assert_equal 'bravo', @engine.storage_participant.first.participant_name
  end

  def test_participant_list_update

    @engine.register_participant 'alpha', Ruote::StorageParticipant

    assert_equal(
      [ '/^alpha$/ ==> Ruote::StorageParticipant {}' ],
      @engine.participant_list.collect { |pe| pe.to_s })

    # 0

    @engine.participant_list = [
      { 'regex' => '^bravo$',
        'classname' => 'Ruote::StorageParticipant',
        'options' => {} },
      { 'regex' => '^charly$',
        'classname' => 'Ruote::StorageParticipant',
        'options' => {} }
    ]

    assert_equal(
      [
        '/^bravo$/ ==> Ruote::StorageParticipant {}',
        '/^charly$/ ==> Ruote::StorageParticipant {}'
      ],
      @engine.participant_list.collect { |pe| pe.to_s })

    # 1

    @engine.participant_list = [
      [ '^charly$', [ 'Ruote::StorageParticipant', {} ] ],
      [ '^bravo$', [ 'Ruote::StorageParticipant', {} ] ]
    ]

    assert_equal(
      [
        '/^charly$/ ==> Ruote::StorageParticipant {}',
        '/^bravo$/ ==> Ruote::StorageParticipant {}'
      ],
      @engine.participant_list.collect { |pe| pe.to_s })

    # 2

    @engine.participant_list = [
      [ '^delta$', Ruote::StorageParticipant, {} ],
      [ '^echo$', 'Ruote::StorageParticipant', {} ]
    ]

    assert_equal(
      [
        '/^delta$/ ==> Ruote::StorageParticipant {}',
        '/^echo$/ ==> Ruote::StorageParticipant {}'
      ],
      @engine.participant_list.collect { |pe| pe.to_s })
  end

  class ParticipantCharlie; end

  def test_register_block

    @engine.register do
      alpha 'Participants::Alpha', 'flavour' => 'vanilla'
      participant 'bravo', 'Participants::Bravo', :flavour => 'peach'
      participant 'charlie', 'Participants::Charlie'
      participant 'david' do |wi|
        p wi
      end
      catchall 'Participants::Zebda', 'flavour' => 'coconut'
    end

    assert_equal 5, @engine.participant_list.size

    assert_equal(
      %w[ ^alpha$ ^bravo$ ^charlie$ ^david$ ^.+$ ],
      @engine.participant_list.collect { |pe| pe.regex.to_s })

    assert_equal(
      %w[ Participants::Alpha
          Participants::Bravo
          Participants::Charlie
          Ruote::BlockParticipant
          Participants::Zebda ],
      @engine.participant_list.collect { |pe| pe.classname })

    assert_equal(
      %w[ vanilla peach nil nil coconut ],
      @engine.participant_list.collect { |pe|
        (pe.options['flavour'] || 'nil') rescue 'nil'
      })
  end

  def test_register_block_and_block

    @engine.register do
      alpha do |workitem|
        a
      end
      participant 'bravo' do |workitem|
        b
      end
    end

    assert_equal(
      [ [ 'on_workitem' ], [ 'on_workitem' ] ],
      @engine.participant_list.collect { |pe| pe.options.keys })
  end

  def test_register_block_catchall_default

    @engine.register do
      catchall
    end

    assert_equal(
      %w[ Ruote::StorageParticipant ],
      @engine.participant_list.collect { |pe| pe.classname })
  end

  def test_register_block_catch_all

    @engine.register do
      catch_all
    end

    assert_equal(
      %w[ Ruote::StorageParticipant ],
      @engine.participant_list.collect { |pe| pe.classname })
  end

  def test_register_block_override_false

    @engine.register do
      alpha 'KlassA'
      alpha 'KlassB'
    end

    plist = @engine.participant_list

    assert_equal(%w[ ^alpha$ ^alpha$ ], plist.collect { |pe| pe.regex })
    assert_equal(%w[ KlassA KlassB ], plist.collect { |pe| pe.classname })
    assert_equal({}, plist.first.options)
  end

  def test_register_block_clears

    @engine.register 'alpha', 'AlphaParticipant'

    @engine.register do
      bravo 'BravoParticipant'
    end

    assert_equal 1, @engine.participant_list.size
  end

  def test_register_block_clear_option

    @engine.register 'alpha', 'AlphaParticipant'

    @engine.register :clear => false do
      bravo 'BravoParticipant'
    end

    assert_equal 2, @engine.participant_list.size
  end

  def test_argument_error_on_instantiated_participant

    assert_raise ArgumentError do
      @engine.register 'alpha', Ruote::StorageParticipant.new
    end
    assert_raise ArgumentError do
      @engine.register 'alpha', Ruote::StorageParticipant.new, 'hello' => 'kitty'
    end
  end

  class AaParticipant
    include Ruote::LocalParticipant
    attr_reader :opts
    def initialize(opts)
      @opts = opts
    end
  end
  class BbParticipant < AaParticipant
    def accept?(workitem)
      false
    end
  end

  def test_engine_participant

    @engine.register do
      alpha AaParticipant
      bravo BbParticipant
      catchall AaParticipant, :catch_all => 'oh yeah'
    end

    assert_equal AaParticipant, @engine.participant('alpha').class
    assert_equal BbParticipant, @engine.participant('bravo').class

    assert_equal AaParticipant, @engine.participant('charly').class
    assert_equal 'oh yeah', @engine.participant('charly').opts['catch_all']

    assert_equal Ruote::Context, @engine.participant('alpha').context.class
  end
end

