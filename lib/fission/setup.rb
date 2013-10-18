module Fission

  class << self
    def register(name, klass)
      @registration ||= {}
      @registration[name] = klass
    end

    def registration
      @registration || {}
    end

    def setup!
      Fission.registration.each do |key, klass|
        klass.workers = Carnivore::Config.get(:fission, :workers, key)
        src = Carnivore::Source.source(key)
        if(src)
          name = klass.to_s.split('::').last
          src.add_callback(name, klass)
        else
          Carnivore::Utils.warn "Workers defined for non-registered source: #{key}"
        end
      end
    end
  end
end