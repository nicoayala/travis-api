require 'travis/api/app'

class Travis::Api::App
  class Endpoint
    # Artifacts are generated by builds. Currently we only expose logs as
    # artifacts
    #
    # DEPRECATED will be removed as soon as the client uses /logs/:id
    class Artifacts < Endpoint
      # Fetches an artifact by it's *id*.
      get '/:id' do |id|
        respond_with service(:find_log, params)
      end
    end
  end
end
