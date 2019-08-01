require "habitat"
require "http"
require "json"
require "logger"
require "rendezvous-hash"

require "./service"
require "./etcd"

# Transparently manages service discovery through consistent hashing and ETCD
module HoundDog
  class Discovery
    getter service, host, port
    getter service_registration

    def initialize(@service : String, @ip : String, @port : UInt16)
      # Convert hound-dog response to a node-key
      nodes = Service.nodes(@service).map { |n| Service.key_value(n) }
      @rendezvous = RendezvousHash.new(nodes: nodes)

      # Register, get nodes, and monitor changes to the namespace
      @service_registration = Service.new(service: @service, node: {ip: @ip, port: @port})
      spawn {
        @service_registration.register(&->handle_service_message(Service::Event))
      }
    end

    # Consistent hash lookup
    def find(key : String) : Node
      service_value = @rendezvous.find(key)
      Service.node(service_value)
    end

    # Consistent hash nodes
    def nodes : Array(Node)
      @rendezvous.nodes.map &->HoundDog.node(String)
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
  end
end
