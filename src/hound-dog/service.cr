require "etcd"
require "mutex"
require "tasker"

require "./settings"

# Facilitates
# - Watching a namespace.
# - Registering discovery information.
# - Querying nodes under a namespace.
module HoundDog
  class Service
    # Namespace under which all services are registered in etcd
    @@namespace : String = HoundDog.settings.service_namespace

    # Node metadata
    alias Node = NamedTuple(
      ip: String,
      port: Int32,
    )

    private getter etcd_client_lock : Mutex = Mutex.new
    @etcd : Etcd::Client?

    def etcd
      etcd_client_lock.synchronize do
        yield (@etcd ||= HoundDog.etcd_client).as(Etcd::Client)
      end
    end

    # Wrapper for Etcd event subscription
    @watchfeed : Etcd::Watch::Watcher?

    # Lease id for service registration in Etcd
    getter lease_id : Int64? = nil

    def registered?
      !!(lease_id)
    end

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
      return if registered?

      key = node_key
      value = Service.key_value(@node)

      kv = etcd &.kv.range(key).kvs.try &.first?

      # Check for key-value existence
      if kv && kv.key == key && kv.value == value && kv.lease
        @lease_id = kv.lease.as(Int64)
        # Renew lease if key-value and lease present
        return keep_alive(ttl)
      end

      # Secure and maintain lease from etcd
      lease = etcd &.lease.grant(ttl)

      # Register service under namespace
      key_set = !(etcd &.kv.put(key, value, lease: lease[:id]).nil?)
      raise "Failed to register #{@node} under #{@service}" unless key_set

      @lease_id = lease[:id]

      # Types don't normalise from above check, have to cast.
      keep_alive(lease[:ttl])
    end

    # unregister current services
    #
    def unregister
      return unless (id = lease_id)
      lease_deleted = etcd &.lease.revoke(id)

      raise "Failed to unregister #{@node} under #{@service}" unless lease_deleted
      @lease_id = nil
    end

    # List nodes under a service namespace
    #
    def self.nodes(service) : Array(Node)
      namespace = "#{@@namespace}/#{service}/"
      range = HoundDog.etcd_client.kv.range_prefix(namespace).kvs || [] of Etcd::Model::Kv
      range.map do |n|
        self.node(n.value.as(String))
      end
    end

    # List available services
    #
    def self.services
      kvs = HoundDog.etcd_client.kv.range_prefix(@@namespace).kvs || [] of Etcd::Model::Kv
      kvs.compact_map { |r| r.key.as(String).split('/')[1]? }.uniq
    end

    # Remove all keys beneath namespace
    #
    def self.clear_namespace
      HoundDog.etcd_client.kv.delete_prefix(@@namespace)
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
        port: port.to_i,
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
      type: Etcd::Model::WatchEvent::Type,
      namespace: String,
      service: String?,
    )

    # Asynchronous interface
    def self.watch(service, &block : Event ->)
      prefix = "#{@@namespace}/#{service}"
      HoundDog.etcd_client.watch.watch_prefix(prefix) do |events|
        events.each { |event| block.call self.parse_event(event) }
      end
    end

    def self.parse_event(event : Etcd::Model::WatchEvent) : Event
      key = event.kv.key
      tokens = key.split('/')

      {
        key:       key,
        value:     event.kv.value,
        type:      event.type,
        namespace: tokens[0],
        service:   tokens[1]?,
      }
    end

    # Method to defer renewal of lease with a dynamic TTL
    #
    protected def keep_alive(ttl : Int64)
      retry_interval = ttl // 2
      Tasker.instance.in(retry_interval.seconds) do
        if (id = lease_id)
          begin
            renewed_ttl = etcd &.lease.keep_alive(id)
            spawn(same_thread: true) { self.keep_alive(renewed_ttl) }
          rescue e
            HoundDog.settings.logger.error("in keep_alive: error=#{e.inspect_with_backtrace}")
          end
        end
      end
    end
  end
end
