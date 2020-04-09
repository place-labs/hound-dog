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
      name: String,
      uri: URI,
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

    getter registration_channel : Channel(Int64) = Channel(Int64).new

    getter name : String
    getter node : Node
    getter service : String
    getter uri : URI

    private getter node_key : String

    def initialize(
      @service : String,
      @name : String,
      uri : URI | String
    )
      @uri = uri.is_a?(String) ? URI.parse(uri) : uri
      @node = {name: @name, uri: @uri}
      @node_key = "#{@@namespace}/#{@service}/#{@name}"
    end

    # Registers a node under a service namespace, passing events under namespace to the callback
    # Check for a existing key-value, and renews its lease if present
    # Effects
    # - Sets node key under service namespace
    # - Spawns a fiber to maintain the lease
    def register(ttl : Int64 = HoundDog.settings.etcd_ttl)
      return if registered?
      @registration_channel = Channel(Int64).new if registration_channel.closed?

      kv = etcd &.kv.range(node_key).kvs.try &.first?

      # Check for key-value existence
      ttl = if kv && kv.key == node_key && kv.value == uri && kv.lease
              @lease_id = kv.lease.as(Int64)

              # Renew lease if key-value and lease present
              ttl
            else
              new_lease(ttl)
            end

      HoundDog.settings.logger.debug { "registered lease #{lease_id} for #{node_key}" }

      begin
        registration_channel.send(lease_id.as(Int64))
      rescue Channel::ClosedError
      end

      keep_alive(ttl)
    end

    # Unregister current service node
    #
    def unregister
      return unless (id = lease_id)
      lease_deleted = etcd &.lease.revoke(id)

      raise "Failed to unregister #{@node} under #{@service}" unless lease_deleted
      registration_channel.close unless registration_channel.closed?
      @lease_id = nil
    end

    # Service Namespace
    ###########################################################################

    # List nodes under a service namespace
    #
    def self.nodes(service) : Array(Node)
      namespace = "#{@@namespace}/#{service}/"
      range = HoundDog.etcd_client.kv.range_prefix(namespace).kvs || [] of Etcd::Model::Kv
      range.compact_map do |n|
        # Parse an Etcd KV into a Node
        n.value.try { |v| self.node(key: n.key, value: v) }
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

    # Monitoring
    ###########################################################################

    # Start monitoring the service namespace
    #
    def monitor(&callback : Event ->)
      unmonitor if @watchfeed
      @watchfeed = Service.watch(@service, &callback)
    end

    # Stop monitoring the service namespace
    #
    def unmonitor
      @watchfeed.try &.stop
      @watchfeed = nil
    end

    # Utils
    ###########################################################################

    # Construct a node
    #
    def self.node(key : String, value : String) : Node
      {
        name: self.name_from_key(key),
        uri:  URI.parse(value),
      }
    end

    # Extract node name from key
    #
    def self.name_from_key(key : String)
      key.split('/').last
    end

    # Watching
    ########################################################################

    alias EventType = ::Etcd::Model::WatchEvent::Type

    alias Event = NamedTuple(
      key: String,
      value: String?,
      type: EventType,
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
      loop do
        id = lease_id
        if id.nil?
          HoundDog.settings.logger.info { "in keep_alive: stopped keep_alive" }
          break
        end

        start = Time.monotonic
        Tasker.instance.in(retry_interval.seconds) do
          begin
            elapsed = Time.monotonic - start
            if elapsed > ttl.seconds
              # Attempt to renew if lease has expired
              HoundDog.settings.logger.warn { "in keep_alive: lost lease #{id} for #{node_key}" }
              ttl = new_lease(ttl)
            else
              # Otherwise keep alive lease
              renewed_ttl = etcd &.lease.keep_alive(id.as(Int64))
              ttl = renewed_ttl unless renewed_ttl.nil? || lease_id.nil?
            end
          rescue e
            HoundDog.settings.logger.error { "in keep_alive: #{e.inspect_with_backtrace}" }
          end
        end.get
      end
    end

    protected def new_lease(ttl)
      # Secure and maintain lease from etcd
      lease = etcd &.lease.grant(ttl)

      # Register service under namespace
      key_set = !(etcd &.kv.put(node_key, uri, lease: lease[:id]).nil?)
      raise "Failed to register #{@node} under #{@service}" unless key_set

      @lease_id = lease[:id]

      lease[:ttl]
    end
  end
end
