module Fission

  class << self
    def register(*args)
      key = args[0, args.size - 1].join('.')
      @registration ||= {}
      @registration[key] ||= []
      @registration[key].push(klass).uniq!
    end

    def registration
      @registration || {}
    end

    def setup!
      Fission.registration.each do |key, klasses|
        klasses.each do |klass|
          klass.workers = Carnivore::Config.get(:fission, :workers, *key.split('.'))
          src = Carnivore::Source.source(key)
          if(src)
            name = klass.to_s.split('::').last
            src.add_callback(name, klass)
          else
            Carnivore::Utils.warn "Workers defined for non-registered source: #{key}"
          end
        end
      end

      # Setup process manager if needed
      if(Carnivore::Config.get(:fission, :utils, :process, :max_processes).to_i > 0)
        require 'fission/utils/process'
        if(Carnivore::Config.get(:fission, :utils, :process, :spawn))
          ChildProcess.posix_spawn = true
        end
        Utils::Process.supervise_as :process_manager
      end
    end
  end
end
