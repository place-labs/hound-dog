require "etcd"
require "http"
require "json"
require "log"
require "rendezvous-hash"
require "ulid"
require "uri"

require "./service"
require "./settings"

# Transparently manage service discovery through consistent hashing and ETCD
module HoundDog
  class Discovery
    Log = ::Log.for(self)

    alias Callback = Array(Service::Node) ->

    getter rendezvous : RendezvousHash

    private getter register_callback : Callback? = nil
    private getter on_change : Callback?

    private getter service_events : Service

    # Service methods
    delegate registration_channel, register, registered?, unmonitor, to: service_events

    # Service getters
    delegate lease_id, name, node, service, uri, to: service_events

    def initialize(
      service : String,
      name : String = ULID.generate,
      uri : URI | String = URI.new(host: "127.0.0.1", port: 8080, scheme: "http"),
      watchfeed : Bool = true,
      @on_change : Callback? = nil
    )
      # Get service nodes
      @service_events = Service.new(
        service: service,
        name: name,
        uri: uri,
      )

      # Initialiase the hash
      @rendezvous = RendezvousHash.new(nodes: etcd_nodes)

      if watchfeed
        # Prepare watchfeed
        feed = service_events.monitor(&->handle_service_message(Service::Event))

        # ASYNC! spawn service monitoring
        spawn(same_thread: true) { feed.start }

        Fiber.yield
      end
    end

    # Consistent hash lookup
    def find?(key : String) : Service::Node?
      rendezvous.find?(key).try &->Discovery.from_hash_value(String)
    end

    # Consistent hash lookup
    def find(key : String) : Service::Node
      Discovery.from_hash_value(rendezvous.find(key))
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
      find?(key) == node
    end

    # Nodes from the `rendezvous-hash`
    #
    def nodes : Array(Service::Node)
      rendezvous.nodes.map &->Discovery.from_hash_value(String)
    end

    # Construct a mapping of node names their URIs
    def node_hash : Hash(String, URI)
      rendezvous
        .nodes
        .map(&->Discovery.from_hash_value(String))
        .each_with_object({} of String => URI) do |node, hash|
          hash[node[:name]] = node[:uri]
        end
    end

    # Register service
    #
    def register(&register_callback : Array(Service::Node) ->)
      @register_callback = register_callback
      service_events.register
    end

    # Unregister service
    #
    def unregister
      service_events.unregister
      rendezvous.remove?(Discovery.to_hash_value(node))

      nil
    end

    # Event handler
    #
    private def handle_service_message(event : Service::Event)
      nodes = Service.nodes(service)
      rendezvous.nodes = nodes.map &->Discovery.to_hash_value(Service::Node)

      # Trigger change callbacks if present
      on_change.try &.call(nodes)
      register_callback.try &.call(nodes)
    end

    # Nodes under the service namespace in `rendezvous-hash` value format
    #
    private def etcd_nodes
      Service.nodes(service).map &->Discovery.to_hash_value(Service::Node)
    end

    # Convert a `Service::Node` to a `rendezvous-hash` formatted value
    #
    def self.to_hash_value(node : Service::Node)
      "#{node[:name]}:#{node[:uri]}"
    end

    # Convert a `rendezvous-hash` formatted value to a `Service::Node`
    #
    def self.from_hash_value(hash_node : String) : Service::Node
      name, _, uri_string = hash_node.partition(":")
      {name: name, uri: URI.parse(uri_string)}
    end

    def finalize
      unmonitor
      unregister
    end
  end
end
