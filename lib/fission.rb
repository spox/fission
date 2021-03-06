require 'jackal'
require 'fission/version'

# Hash processor framework
module Fission
  autoload :Version, 'fission/version'
  autoload :Callback, 'fission/callback'
  autoload :Cli, 'fission/cli'
  autoload :Error, 'fission/exceptions'
  autoload :Utils, 'fission/utils'
  autoload :Transports, 'fission/transports'
  autoload :Formatter, 'fission/formatter'
  autoload :Runner, 'fission/runner'

  # proxy to jackal
  def self.service(*args)
    Jackal.service(*args)
  end

  # proxy to jackal
  def self.service_info
    Jackal.service_info
  end
end

autoload :Smash, 'fission/utils/smash'

# Force fission customized methods into jackal
module Jackal::Utils
  extend Fission::Utils::Payload
  extend Fission::Utils::MessageUnpack
end

# Force load callbacks so jackals are auto built within fission
require 'fission/callback'

require 'fission/setup'
