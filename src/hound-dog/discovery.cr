require "habitat"
require "http"
require "json"
require "logger"
require "rendezvous-hash"

require "./service"
require "./etcd"

# Transparently manage service discovery through consistent hashing and ETCD
#
module HoundDog
  class Discovery
    getter service, ip, port
    getter service_registration

    @registration : Service?

    # TODO:
    # - remove coupling between registration and monitoring
    # - graceful retry for both registration and monitoring

    def initialize(@service : String, @ip : String, @port : UInt16)
      # Get service nodes
      nodes = Service.nodes(@service).map { |n| Service.key_value(n) }

      @rendezvous = RendezvousHash.new(nodes: nodes)
    end

    # Register and monitor changes to namespace
    #
    def register
      # Register service
      @registration = registration = Service.new(service: @service, node: {ip: @ip, port: @port})
      registration.register(&->handle_service_message(Service::Event))
      @rendezvous.add({ip: @ip, port: @port})
    end

    # Remove self from namespace, stop monitoring.
    def unregister
      @registration.try &.unregister
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

    # HoundDog Event Handler
    #############################################################################

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
      if (registration = @registration) && registration.registered?
        registration.unregister
      end
    end
  end
end
