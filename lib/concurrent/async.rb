require 'thread'
require 'concurrent/configuration'
require 'concurrent/errors'
require 'concurrent/ivar'
require 'concurrent/executor/single_thread_executor'

module Concurrent

  # A mixin module that provides simple asynchronous behavior to any standard
  # class/object or object. 
  # 
  # ```cucumber
  # Feature:
  #   As a stateful, plain old Ruby class/object
  #   I want safe, asynchronous behavior
  #   So my long-running methods don't block the main thread
  # ```
  # 
  # Stateful, mutable objects must be managed carefully when used asynchronously.
  # But Ruby is an object-oriented language so designing with objects and classes
  # plays to Ruby's strengths and is often more natural to many Ruby programmers.
  # The `Async` module is a way to mix simple yet powerful asynchronous capabilities
  # into any plain old Ruby object or class. These capabilities provide a reasonable
  # level of thread safe guarantees when used correctly.
  # 
  # When this module is mixed into a class, objects of the class become inherently
  # asynchronous. Each object gets its own background thread on which to post
  # asynchronous method calls. Asynchronous method calls are executed in the
  # background one at a time in the order they are received.
  #
  # Mixing this module into a class provides each object two proxy methods:
  # `async` and `await`. These methods are thread safe with respect to the enclosing
  # object. The former method allows methods to be called asynchronously by posting
  # to the object's private thread. The latter allows a method to be called synchronously
  # but does so safely with respect to any pending asynchronous method calls
  # and ensures proper ordering. Both methods return a {Concurrent::IVar} which can
  # be inspected for the result of the method call. Calling a method with `async` will
  # return a `:pending` `IVar` whereas `await` will return a `:complete` `IVar`.
  # 
  # ### An Important Note About Thread Safe Guarantees
  # 
  # > Thread safe guarantees can only be made when asynchronous method calls
  # > are not mixed with direct method calls. Use only direct method calls
  # > when the object is used exclusively on a single thread. Use only
  # > `async` and `await` when the object is shared between threads. Once you
  # > call a method using `async` or `await`, you should no longer call methods
  # > directly on the object. Use `async` and `await` exclusively from then on.
  # 
  # @example
  # 
  #   class Echo
  #     include Concurrent::Async
  #   
  #     def echo(msg)
  #       sleep(rand)
  #       print "#{msg}\n"
  #       nil
  #     end
  #   end
  #   
  #   horn = Echo.new
  #   horn.echo('zero')      # synchronous, not thread-safe
  #   
  #   horn.async.echo('one') # asynchronous, non-blocking, thread-safe
  #   horn.await.echo('two') # synchronous, blocking, thread-safe
  #
  # @see Concurrent::IVar
  # @see Concurrent::SingleThreadExecutor
  module Async

    # @!method self.new(*args, &block)
    #
    #   Instanciate a new object and ensure proper initialization of the
    #   synchronization mechanisms.
    #
    #   @param [Array<Object>] args Zero or more arguments to be passed to the
    #     object's initializer.
    #   @param [Proc] block Optional block to pass to the object's initializer.
    #   @return [Object] A properly initialized object of the asynchronous class.

    # Check for the presence of a method on an object and determine if a given
    # set of arguments matches the required arity.
    #
    # @param [Object] obj the object to check against
    # @param [Symbol] method the method to check the object for
    # @param [Array] args zero or more arguments for the arity check
    #
    # @raise [NameError] the object does not respond to `method` method
    # @raise [ArgumentError] the given `args` do not match the arity of `method`
    #
    # @note This check is imperfect because of the way Ruby reports the arity of
    #   methods with a variable number of arguments. It is possible to determine
    #   if too few arguments are given but impossible to determine if too many
    #   arguments are given. This check may also fail to recognize dynamic behavior
    #   of the object, such as methods simulated with `method_missing`.
    #
    # @see http://www.ruby-doc.org/core-2.1.1/Method.html#method-i-arity Method#arity
    # @see http://ruby-doc.org/core-2.1.0/Object.html#method-i-respond_to-3F Object#respond_to?
    # @see http://www.ruby-doc.org/core-2.1.0/BasicObject.html#method-i-method_missing BasicObject#method_missing
    #
    # @!visibility private
    def self.validate_argc(obj, method, *args)
      argc = args.length
      arity = obj.method(method).arity

      if arity >= 0 && argc != arity
        raise ArgumentError.new("wrong number of arguments (#{argc} for #{arity})")
      elsif arity < 0 && (arity = (arity + 1).abs) > argc
        raise ArgumentError.new("wrong number of arguments (#{argc} for #{arity}..*)")
      end
    end

    # @!visibility private
    def self.included(base)
      base.singleton_class.send(:alias_method, :original_new, :new)
      base.extend(ClassMethods)
      super(base)
    end

    # @!visibility private
    module ClassMethods
      def new(*args, &block)
        obj = original_new(*args, &block)
        obj.send(:init_synchronization)
        obj
      end
    end
    private_constant :ClassMethods

    # Delegates asynchronous, thread-safe method calls to the wrapped object.
    #
    # @!visibility private
    class AsyncDelegator

      # Create a new delegator object wrapping the given delegate,
      # protecting it with the given serializer, and executing it on the
      # given executor. Block if necessary.
      #
      # @param [Object] delegate the object to wrap and delegate method calls to
      # @param [Concurrent::ExecutorService] executor the executor on which to execute delegated method calls
      # @param [Boolean] blocking will block awaiting result when `true`
      def initialize(delegate, executor, blocking)
        @delegate = delegate
        @executor = executor
        @blocking = blocking
      end

      # Delegates method calls to the wrapped object. For performance,
      # dynamically defines the given method on the delegator so that
      # all future calls to `method` will not be directed here.
      #
      # @param [Symbol] method the method being called
      # @param [Array] args zero or more arguments to the method
      #
      # @return [IVar] the result of the method call
      #
      # @raise [NameError] the object does not respond to `method` method
      # @raise [ArgumentError] the given `args` do not match the arity of `method`
      def method_missing(method, *args, &block)
        super unless @delegate.respond_to?(method)
        Async::validate_argc(@delegate, method, *args)

        self.define_singleton_method(method) do |*method_args|
          Async::validate_argc(@delegate, method, *method_args)
          ivar = Concurrent::IVar.new
          @executor.post(method_args) do |arguments|
            begin
              ivar.set(@delegate.send(method, *arguments, &block))
            rescue => error
              ivar.fail(error)
            end
          end
          ivar.wait if @blocking
          ivar
        end

        self.send(method, *args)
      end
    end
    private_constant :AsyncDelegator

    # Causes the chained method call to be performed asynchronously on the
    # object's thread. The delegated method will return a future in the
    # `:pending` state and the method call will have been scheduled on the
    # object's thread. The final disposition of the method call can be obtained
    # by inspecting the returned future.
    #
    # @!macro [attach] async_thread_safety_warning
    #   @note The method call is guaranteed to be thread safe with respect to
    #     all other method calls against the same object that are called with
    #     either `async` or `await`. The mutable nature of Ruby references
    #     (and object orientation in general) prevent any other thread safety
    #     guarantees. Do NOT mix direct method calls with delegated method calls.
    #     Use *only* delegated method calls when sharing the object between threads.
    #
    # @return [Concurrent::IVar] the pending result of the asynchronous operation
    #
    # @raise [NameError] the object does not respond to the requested method
    # @raise [ArgumentError] the given `args` do not match the arity of
    #   the requested method
    def async
      @__async_delegator__
    end

    # Causes the chained method call to be performed synchronously on the
    # current thread. The delegated will return a future in either the
    # `:fulfilled` or `:rejected` state and the delegated method will have
    # completed. The final disposition of the delegated method can be obtained
    # by inspecting the returned future.
    #
    # @!macro async_thread_safety_warning
    #
    # @return [Concurrent::IVar] the completed result of the synchronous operation
    #
    # @raise [NameError] the object does not respond to the requested method
    # @raise [ArgumentError] the given `args` do not match the arity of the
    #   requested method
    def await
      @__await_delegator__
    end

    private

    # Initialize the internal serializer and other stnchronization mechanisms.
    #
    # @note This method *must* be called immediately upon object construction.
    #   This is the only way thread-safe initialization can be guaranteed.
    #
    # @!visibility private
    def init_synchronization
      return self if @__async_initialized__
      @__async_initialized__ = true
      @__async_executor__ = Concurrent::SingleThreadExecutor.new(
        fallback_policy: :caller_runs, auto_terminate: true)
      @__await_delegator__ = AsyncDelegator.new(self, @__async_executor__, true)
      @__async_delegator__ = AsyncDelegator.new(self, @__async_executor__, false)
      self
    end
  end
end
