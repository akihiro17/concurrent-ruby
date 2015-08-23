require 'concurrent/configuration'
require 'concurrent/atomic/atomic_reference'
#require 'concurrent/collection/copy_on_write_observer_set'
require 'concurrent/concern/dereferenceable'
#require 'concurrent/concern/observable'
require 'concurrent/synchronization/object'

module Concurrent

  # `Agent`s are inspired by [Clojure's](http://clojure.org/) [agent](http://clojure.org/agents) function. An `Agent` is a single atomic value that represents an identity. The current value of the `Agent` can be requested at any time (`deref`). Each `Agent` has a work queue and operates on the global thread pool (see below). Consumers can `post` code blocks to the `Agent`. The code block (function) will receive the current value of the `Agent` as its sole parameter. The return value of the block will become the new value of the `Agent`. `Agent`s support two error handling modes: fail and continue. A good example of an `Agent` is a shared incrementing counter, such as the score in a video game. 
  class Agent < Synchronization::Object
    include Concern::Dereferenceable
    #include Concern::Observable

    ERROR_MODES = [:continue, :fail].freeze

    AWAIT_ACTION = ->(agent, value, latch){ latch.count_down }
    private_constant :AWAIT_ACTION

    class Job
      attr_reader :action, :args, :executor, :caller
      def initialize(action, args, executor)
        @action = action
        @args = args
        @executor = executor
        @caller = Thread.current.object_id
      end
    end
    private_constant :Job

    class Error < StandardError
      def initialize(message = nil)
        message ||= 'agent must be restarted before jobs can post'
      end
    end

    attr_reader :error_mode

    def initialize(initial, opts = {})
      super()
      synchronize { ns_initialize(initial, opts) }
    end

    def value
      apply_deref_options(@current.value)
    end

    def error
      @error.value
    end

    def send(*args, &action)
      enqueue_action_job(action, args, Concurrent.global_fast_executor)
    end

    def send!(*args, &action)
      raise Error.new unless send(*args, &action)
    end

    def send_off(*args, &action)
      enqueue_action_job(action, args, Concurrent.global_io_executor)
    end
    alias_method :post, :send_off

    def send_off!(*args, &action)
      raise Error.new unless send_off(*args, &action)
    end

    def send_via(executor, *args, &action)
      enqueue_action_job(action, args, executor)
    end

    def send_via!(executor, *args, &action)
      raise Error.new unless send_via(*args, &action)
    end

    def <<(action)
      send_off(&action)
    end

    def await
      wait(nil)
    end

    def await_for(timeout)
      wait(timeout.to_f)
    end

    def await_for!(timeout)
      raise Concurrent::TimeoutError unless wait(timeout.to_f)
      true
    end

    def wait(timeout = nil)
      latch = Concurrent::CountDownLatch.new(1)
      enqueue_await_job(latch)
      latch.wait(timeout)
    end

    def stopped?
      !@error.value.nil?
    end

    def restart(new_value, opts = {})
      clear_actions = opts.fetch(:clear_actions, false)
      synchronize do
        raise Error.new('agent is not stopped') unless stopped?
        raise Error.new('invalid value') unless ns_validate(new_value)
        @error.value = nil
        if clear_actions
          @queue.clear
        elsif !@queue.empty?
          ns_post_next_job
        end
      end
      true
    end

    class << self

      def await(*agents)
        agents.each {|agent| agent.await }
      end

      def await_for(timeout, *agents)
        end_at = Concurrent.monotonic_time + timeout.to_f
        agents.each do |agent|
          break false unless agent.await_for(end_at - Concurrent.monotonic_time)
          true
        end
      end

      def await_for!(timeout, *agents)
        raise Concurrent::TimeoutError unless await_for(timeout_agents)
        true
      end
    end

    private

    def ns_initialize(initial, opts)
      @error_mode = opts[:error_mode]
      @error_handler = opts[:error_handler]

      if @error_mode && !ERROR_MODES.include?(@error_mode)
        raise ArgumentError.new('unrecognized error mode')
      elsif @error_mode.nil?
        @error_mode = @error_handler ? :continue : :fail
      end

      @error_handler ||= ->(agent, exception){ nil }
      @validator = opts.fetch(:validator, ->(value){ true })
      @current = Concurrent::AtomicReference.new(initial)
      @error = Concurrent::AtomicReference.new(nil)
      @queue = []

      init_mutex(self)
      ns_set_deref_options(opts)
    end

    def enqueue_action_job(action, args, executor)
      raise ArgumentError.new('no action given') unless action
      job = Job.new(action, args, executor)
      synchronize { ns_enqueue_job(job) }
    end

    def enqueue_await_job(latch)
      synchronize do
        if (index = ns_find_last_job_for_thread)
          job = Job.new(AWAIT_ACTION, [latch],
                        Concurrent.global_immdediate_executor)
          ns_enqueue_job(job, index)
        else
          latch.count_down
          true
        end
      end
    end

    def ns_enqueue_job(job, index = nil)
      return false if stopped?
      index ||= @queue.length
      @queue.insert(index, job)
      # if this is the only job, post to executor
      ns_post_next_job if @queue.length == 1
      true
    end

    def ns_post_next_job
      @queue.first.executor.post{ execute_next_job }
    end

    def execute_next_job
      job = synchronize { @queue.first }
      new_value = job.action.call(self, @current.value, *job.args)
      @current.value = new_value if ns_validate(new_value)
    rescue => error
      handle_error(error)
    ensure
      synchronize do
        @queue.shift
        unless stopped? || @queue.empty?
          ns_post_next_job
        end
      end
    end

    def ns_validate(value)
      @validator.call(value)
    rescue
      false
    end

    def handle_error(error)
      # stop new jobs from posting
      @error.value = error if @error_mode == :fail
      @error_handler.call(self, error)
    rescue
      #do nothing
    end

    def ns_find_last_job_for_thread
      @queue.rindex {|job| job.caller == Thread.current.object_id }
    end
  end
end
