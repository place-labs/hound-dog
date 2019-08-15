require "habitat"
require "http"
require "json"
require "rendezvous-hash"

require "./etcd"
require "./service"
require "./settings"

# Transparently manage service discovery through consistent hashing and ETCD
#
module HoundDog
  class Discovery
    getter service, ip, port

    def initialize(
      @service : String,
      @ip : String = "127.0.0.1",
      @port : UInt16 = 8080
    )
      # Get service nodes
      nodes = Service.nodes(@service).map { |n| Service.key_value(n) }
      @service_events = Service.new(
        service: @service,
        node: {ip: @ip, port: @port},
      )

      # Initialiase the hash
      @rendezvous = RendezvousHash.new(nodes: nodes)

      # Prepare watchfeed
      watchfeed = @service_events.monitor(&->handle_service_message(Service::Event))

      # ASYNC! spawn service monitoring
      spawn watchfeed.start
    end

    # Register service
    #
    def register
      @service_events.register
    end

    # Remove self from namespace
    #
    def unregister
      @service_events.unregister
    end

    # Consistent hash lookup
    #
    def find(key : String) : Service::Node
      service_value = @rendezvous.find(key)
      Service.node(service_value)
    end

    # Consistent hash nodes
    #
    def nodes : Array(Service::Node)
      @rendezvous.nodes.map &->Service.node(String)
    end

    # Event handler
    #
    def handle_service_message(event : Service::Event)
      key = event[:key]
      value = event[:value]

      case event[:type]
      when Etcd::WatchEvent::Type::PUT
        @rendezvous.add(value) if value
      when Etcd::WatchEvent::Type::DELETE
        # Only have the key on delete events
        ip = key.split('/').last
        node = @rendezvous.nodes.find &.starts_with?(ip)
        @rendezvous.remove?(node) if node
      end
    end

    def finalize
      @service_events.unmonitor
      unregister
    end
  end
end
