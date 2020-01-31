require "etcd"
require "http"
require "json"
require "rendezvous-hash"

require "./service"
require "./settings"

# Transparently manage service discovery through consistent hashing and ETCD
module HoundDog
  class Discovery
    getter service, ip, port, node, rendezvous
    private getter callback : Proc(Void)? = nil
    private getter service_events : Service

    def initialize(
      @service : String,
      @ip : String = "127.0.0.1",
      @port : Int32 = 8080
    )
      @node = {ip: ip, port: port}

      # Get service nodes
      @service_events = Service.new(
        service: service,
        node: node,
      )

      # Initialiase the hash
      @rendezvous = RendezvousHash.new(nodes: etcd_nodes)

      # Prepare watchfeed
      watchfeed = service_events.monitor(&->handle_service_message(Service::Event))

      # ASYNC! spawn service monitoring
      spawn(same_thread: true) { watchfeed.start }
      Fiber.yield
    end

    # Consistent hash lookup
    def find?(key : String) : Service::Node?
      rendezvous.find?(key).try &->Service.node(String)
    end

    # Consistent hash lookup
    def find(key : String) : Service::Node
      Service.node(rendezvous.find(key))
    end

    def [](key)
      find(key)
    end

    def []?(key)
      find?(key)
    end

    # Determine if key maps to current node
    #
    def own_node?(key : String) : Bool
      service_value = rendezvous[key]?
      !!(service_value && Service.node(service_value) == node)
    end

    # Consistent hash nodes
    #
    def nodes : Array(Service::Node)
      rendezvous.nodes.map &->Service.node(String)
    end

    delegate register, lease_id, registered?, unmonitor, to: service_events

    # Register service
    #
    def register(&callback : Proc(Void))
      @callback = callback
      service_events.register
    end

    def unregister
      service_events.unregister
      rendezvous.remove?(Service.key_value(node))

      nil
    end

    # Event handler
    #
    private def handle_service_message(event : Service::Event)
      rendezvous.nodes = etcd_nodes
      # Trigger change callback if present
      callback.try &.call
    end

    private def etcd_nodes
      Service.nodes(service).map { |n| Service.key_value(n) }
    end

    def finalize
      unmonitor
      unregister
    end
  end
end
