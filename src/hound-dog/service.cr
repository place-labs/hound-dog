require "tasker"

require "./etcd"
require "./settings"

# - watch namespace
# - register self
# - add nodes from etcd

module HoundDog
  class Service
    # Namespace under which all services are registered in etcd
    getter namespace
    @@namespace : String = HoundDog.settings.service_namespace

    # Node metadata
    alias Node = NamedTuple(
      ip: String,
      port: UInt16,
    )

    # Class level http client
    @@etcd = HoundDog::Etcd.new(
      host: HoundDog.settings.etcd_host,
      port: HoundDog.settings.etcd_port,
    )

    # Wrapper for Etcd event subscription
    @watchfeed : Etcd::WatchFeed?

    # Flag for lease renewal
    getter registered = false

    def initialize(@service : String, @node : Node)
    end

    def node_key
      "#{@@namespace}/#{@service}/#{@node[:ip]}"
    end

    # Registers a node under a service namespace, passing events under namespace to the callback
    # Check for a existing key-value, and renews its lease if present
    # Effects
    # - Sets node key under service namespace
    # - Spawns a fiber to maintain the lease
    def register(ttl : Int64 = HoundDog.settings.etcd_ttl)
      return if @registered

      key = node_key
      value = Service.key_value(@node)

      # Check for key-value existence
      if (kv = @@etcd.range(key).first?)
        if kv.key == key && kv.value == value && kv.lease
          # Renew lease if key-value and lease present
          return keep_alive(kv.lease.as(Int64), ttl)
        end
      end

      # Secure and maintain lease from etcd
      lease = @@etcd.lease_grant ttl

      # Register service under namespace
      @registered = @@etcd.put(key, value, lease: lease[:id]).as(Bool)
      raise "Failed to register #{@node} under #{@service}" unless @registered

      # Types don't normalise from above check, have to cast.
      keep_alive(lease[:id], lease[:ttl])
    end

    # unregister current services
    #
    def unregister
      @registered = @@etcd.delete(node_key) == 0 if @registered
      !@registered
    end

    # List nodes under a service namespace
    #
    def self.nodes(service) : Array(Node)
      namespace = "#{@@namespace}/#{service}/"
      range = @@etcd.range_prefix namespace
      range.map do |n|
        self.node(n.value.as(String))
      end
    end

    # List available services
    #
    def self.services
      @@etcd.range_prefix(@@namespace).compact_map do |r|
        r.key.as(String).split('/')[1]?
      end.uniq
    end

    # Utils
    ###########################################################################

    def self.key_value(node : Node) : String
      "#{node[:ip]}:#{node[:port]}"
    end

    def self.node(key : String) : Node
      ip, port = key.split(':')
      {
        ip:   ip,
        port: port.to_u16,
      }
    end

    def monitor(&callback : Event ->)
      @watchfeed = Service.watch(@service, &callback)
    end

    def unmonitor
      @watchfeed.try &.stop
    end

    # Watching
    ########################################################################

    alias Event = NamedTuple(
      key: String,
      value: String?,
      type: Etcd::WatchEvent::Type,
      namespace: String,
      service: String?,
    )

    # Asynchronous interface
    def self.watch(service, &block : Event ->)
      prefix = "#{@@namespace}/#{service}"
      @@etcd.watch_prefix(prefix) do |events|
        events.each { |event| block.call self.parse_event(event) }
      end
    end

    def self.parse_event(event : Etcd::WatchEvent) : Event
      kv = event.kv.as(Etcd::KV)
      event_type = event.type.as(Etcd::WatchEvent::Type)
      key = kv.key.as(String)
      tokens = key.split('/')

      {
        key:       key,
        value:     kv.value,
        type:      event_type,
        namespace: tokens[0],
        service:   tokens[1]?,
      }
    end

    # Method to defer renewal of lease with a dynamic TTL
    #
    protected def keep_alive(id : Int64, ttl : Int64)
      retry_interval = ttl // 2
      Tasker.instance.in(retry_interval.seconds) do
        if @registered
          begin
            renewed_ttl = @@etcd.lease_keep_alive id
            spawn self.keep_alive(id, renewed_ttl)
          rescue e
            HoundDog.settings.logger.error("in keep_alive: error=#{e.inspect_with_backtrace}")
          end
        end
      end
    end
  end
end
