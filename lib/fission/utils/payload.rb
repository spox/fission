module Fission
  module Utils

    module Payload

      # job:: name of job
      # payload:: Hash or String payload (will attempt JSON loading)
      # args:: optional flags
      # Creates a new payload Hash nesting the original payload within
      # `:data` and setting the `:job` and `:message_id`
      def new_payload(job, payload, *args)
        if(payload.is_a?(String))
          begin
            payload = MultiJson.load(payload)
          rescue MultiJson::DecodeError
            if(args.include?(:json_required))
              raise
            else
              warn 'Failed to convert payload from string to class. Setting as string value'
              debug "Un-JSONable string: #{payload.inspect}"
            end
          end
        end
        Smash.new(
          :job => job,
          :message_id => Celluloid.uuid,
          :data => payload,
          :complete => []
        )
      end

      # payload:: data payload
      # key:: Format request key
      # source:: Source of payload
      # Extract generic information from payload
      def format_payload(payload, key, source=nil)
        begin
          source = payload[:source] unless source
          Formatter.format(key, source, payload)
        rescue => e
          debug "Aborting rescued exception -> #{e.class}: #{e}\n#{e.backtrace.join("\n")}"
          abort e
        end
      end

    end

  end
end