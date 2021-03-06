require 'fission'
require 'shellwords'
require 'fileutils'
require 'tempfile'
require 'childprocess'

module Fission
  module Utils
    # Helper class for running processes on the system
    class Process < Jackal::Utils::Process

      # Environment variables that should be removed from process environment
      BLACKLISTED_ENV = ['GIT_DIR']

      include Zoidberg::SoftShell
      include Carnivore::Utils::Logging

      # Creates new Process actor
      def initialize
        @registry = Smash.new
        @locker = Smash.new
        @base_env = ENV.to_hash
        @max_processes = Carnivore::Config.get(:fission, :utils, :process_manger, :max_processes) || 5
        @storage_directory = Carnivore::Config.get(:fission, :utils, :process_manager, :storage) ||
          '/tmp/fission/process_manager'
        FileUtils.mkdir_p(@storage_directory)

        every((Carnivore::Config.get(:fission, :utils, :process_manager, :poll) || 2.0).to_f){ check_running_procs }
        # configurable (also conditional - start stop based on active
        # non-notified processes in registry)
      end

      # Registers provided command.
      #
      # @param identifier [String] unique identifier
      # @param command [String] command string or array and optional hash
      # @option command :source [Symbol] source location send completion notification
      # @option command :payload [Hash] payload for notification (merged with result)
      # @option command :pending [Hash] interval pending notifications
      # @option :pending :interval [Numeric] seconds between notifications
      # @option :pending :source [Symbol] source location to transmit
      # @option :pending :reference [String] unique identifier
      # @option :pending :data [Hash] data to be sent in notification payload
      # @yield process instance provided to block
      # @return [TrueClass]
      def process(identifier, *command)
        opts = command.detect{|i| i.is_a?(Hash)} || {}
        command.delete(opts)
        if(command.empty?)
          if(@registry.has_key?(identifier))
            p_lock = lock(identifier, false)
            if(p_lock)
              yield p_lock[:process]
              unlock(p_lock)
              true
            else
              abort Locked.new("Requested process is currently locked (#{identifier})")
            end
          else
            abort KeyError.new("Provided identifer is not currently registered (#{identifier})")
          end
        else
          if(@registry.has_key?(identifier))
            abort KeyError.new("Provided identifier already in use (#{identifier.inspect})")
          else
            check_process_limit!
            if(command.size == 1)
              command = Shellwords.shellsplit(command.first)
            end
            _proc = clean_env!{ ChildProcess.build(*command) }
            scrub_env(_proc.environment)
            @registry.merge!(
              Smash.new(
                identifier => opts.to_smash.merge(
                  :process => _proc,
                  :command => command.join(' '),
                  :start_time => Time.now.to_f
                )
              )
            )
            if(block_given?)
              p_lock = lock(identifier)
              clean_env!{ yield p_lock[:process] }
              unlock(p_lock)
              true
            end
            @registry[identifier][:reference] = opts[:pending][:reference]
            @registry[identifier][:pending_data] = opts[:pending][:data]
            if(opts[:pending] && opts[:pending][:interval])
              start_pending_notifier(
                identifier, opts[:pending][:source], opts[:pending][:interval]
              )
            end
          end
        end
        true
      end

      # Generate status report for process
      #
      # @param identifier [String] process identifier
      # @param registry_entry [Hash]
      # @return [Hash]
      def generate_process_status(identifier, registry_entry)
        Smash.new(
          :process_manager => Smash.new(
            :state => Smash.new(
              :running => registry_entry[:process].alive?,
              :failed => registry_entry[:process].exit_code.nil? && registry_entry[:process].exit_code != 0,
              :process_identifier => identifier,
              :reference_identifier => registry_entry[:reference],
              :data => registry_entry[:pending_data],
              :elapsed_time => Time.now.to_f - registry_entry[:start_time]
            )
          )
        )
      end

      # Start recurring notifier for process
      #
      # @param identifier [String] process identifier
      # @param source [String, Symbol] source to tramsit to
      # @param interval [Numeric] interval in seconds
      # @return [Timer]
      def start_pending_notifier(identifier, source, interval)
        timer = every(interval) do
          debug "Pending notification generation for identifier: #{identifier}"
          p_lock = lock(identifier)
          payload = Fission::Utils.new_payload(source,
            generate_process_status(identifier, p_lock[:registry_entry])
          )
          Fission::Utils.transmit(source, payload)
          unlock(p_lock)
        end
        @registry[identifier][:pending_notifier] = timer
      end

      # Stop process if alive and deregister
      #
      # @param identifier [String] process identifier
      # @return [TrueClass]
      def delete(identifier)
        if(@registry[identifier][:process])
          locked = lock(identifier, false)
          if(locked)
            if(_proc = @registry[identifier][:process])
              if(_proc.alive?)
                _proc.stop
              end
            end
            if(_timer = @registry[identifier][:pending_notifier])
              _timer.cancel
            end
            [@registry, @locker].each{|hsh| hsh.delete(identifier) }
            true
          else
            abort StandardError.new("Failed to lock process (ID: #{identifier})")
          end
        else
          abort KeyError.new("Identifier provided is not registered (#{identifier.inspect})")
        end
      end

      # Lock the process for "exclusive" usage
      #
      # @param identifier [String] process identifier
      # @param wait [TrueClass, FalseClass] wait for lock
      # @return [Hash]
      # @todo re-add optional wait since it's gone now :|
      def lock(identifier, wait=true)
        result = nil
        until(result)
          if(@registry[identifier])
            unless(@locker[identifier])
              @locker[identifier] = Zoidberg.uuid
              result = Smash.new(
                :registry_entry => @registry[identifier],
                :process => @registry[identifier][:process],
                :lock_id => @locker[identifier]
              )
            end
          else
            abort KeyError.new("Requested process not found (identifier: #{identifier}) -- current: #{@registry.keys.sort}")
          end
        end
        result
      end

      # Unlock a locked process
      #
      # @param lock_id [String]
      # @return [TrueClass]
      def unlock(lock_id)
        if(lock_id.is_a?(Hash))
          lock_id = lock_id[:lock_id]
        end
        key = @locker.key(lock_id)
        if(key)
          @locker.delete(key)
          result = true
        else
          abort KeyError.new("Provided lock id is not in use (#{lock_id})")
        end
      end

      # Process with given identifier is locked
      #
      # @param identifier [String]
      # @return [TrueClass, FalseClass]
      def locked?(identifier)
        !!@locker[identifier]
      end

      # Check if max process limit has been met or exceeded
      #
      # @raises [Error::ThresholdExceeded]
      def check_process_limit!
        if(@max_processes)
          not_complete = @registry.values.find_all do |_proc|
            c_proc = _proc[:process]
            begin
              !c_proc.exited?
            rescue ChildProcess::Error => e
              e.message == 'process not started'
            end
          end
          if(not_complete.size >= @max_processes)
            abort Error::ThresholdExceeded.new("Max process threshold reached (#{@max_processes} processes)")
          end
        end
      end

      private

      # Lock the identifier
      #
      # @param identifier [String, Symbol] process identifier
      # @return [Hash]
      def lock_wrapped(identifier)
        lock(identifer)
      end

      # Watchdog for registered processes
      def check_running_procs
        @registry.each do |identifier, _proc|
          if(!locked?(identifier) && !_proc[:notified] && _proc[:source] && !_proc[:process].alive?)
            payload = _proc[:payload] || Smash.new
            payload[:data] ||= Smash.new
            payload[:data].merge!(
              :process_notification => identifier
            )
            payload[:data].merge!(
              generate_process_status(identifier, @registry[identifier])
            )
            _proc[:source].transmit(payload, nil)
            _proc[:notified] = true
          end
        end
      end

      # Remove environment variables that are known should _NOT_ be set
      #
      # @yield execute block within scrubbed environment
      def clean_env!
        ENV.replace(@base_env.dup)
        scrub_env(ENV)
        if(defined?(Bundler))
          Bundler.with_clean_env{ yield }
        else
          yield
        end
      end

      # Scrubs configured keys from hash
      #
      # @param env [Hash] hash to scrub
      # @return [TrueClass]
      def scrub_env(env)
        [
          BLACKLISTED_ENV,
          Carnivore::Config.get(
            :fission, :utils, :process_manager, :blacklisted_env
          )
        ].flatten.compact.each do |key|
          env.delete(key)
        end
        true
      end

    end
  end
end
