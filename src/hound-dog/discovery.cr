require "etcd"
require "http"
require "json"
require "rendezvous-hash"

require "./service"
require "./settings"

# Transparently manage service discovery through consistent hashing and ETCD
#
module HoundDog
  class Discovery
    getter service, ip, port, node
    private getter callback : Proc(Void)? = nil

    def initialize(
      @service : String,
      @ip : String = "127.0.0.1",
      @port : Int32 = 8080
    )
      @node = {ip: @ip, port: @port}

      # Get service nodes
      @service_events = Service.new(
        service: @service,
        node: @node,
      )

      # Initialiase the hash
      @rendezvous = RendezvousHash.new(nodes: current_nodes)

      # Prepare watchfeed
      watchfeed = @service_events.monitor(&->handle_service_message(Service::Event))

      # ASYNC! spawn service monitoring
      spawn(same_thread: true) { watchfeed.start }
    end

    # Consistent hash lookup
    def find(key : String) : Service::Node?
      @rendezvous.find(key).try &->Service.node(String)
    end

    # Consistent hash lookup
    def find!(key : String) : Service::Node
      Service.node(@rendezvous.find!(key))
    end

    # Determine if key maps to current node
    #
    def own_node?(key : String) : Bool
      service_value = @rendezvous.find(key)
      !service_value.nil? && Service.node(service_value) == @node
    end

    # Consistent hash nodes
    #
    def nodes : Array(Service::Node)
      @rendezvous.nodes.map &->Service.node(String)
    end

    delegate register, unregister, lease_id, to: @service_events

    # Register service
    #
    def register(&callback : Proc(Void))
      @callback = callback
      @service_events.register
    end

    def registered?
      @service_events.registered
    end

    # Event handler
    #
    def handle_service_message(event : Service::Event)
      @rendezvous.replace_nodes(current_nodes)
      # Trigger change callback if present
      callback.not_nil!.call if callback
    end

    private def current_nodes
      Service.nodes(@service).map { |n| Service.key_value(n) }
    end

    def finalize
      @service_events.unmonitor
      unregister
    end
  end
end
