require "etcd"
require "log"
require "mutex"
require "retriable"
require "tasker"

require "./settings"

# Facilitates
# - Watching a namespace.
# - Registering discovery information.
# - Querying nodes under a namespace.
module HoundDog
  class Service
    Log = ::Log.for(self)

    # Namespace under which all services are registered in etcd
    class_getter namespace : String = HoundDog.settings.service_namespace

    # Node metadata
    alias Node = NamedTuple(
      name: String,
      uri: URI,
    )

    # Wrapper for Etcd event subscription
    private property watchfeed : Etcd::Watch::Watcher?

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

    @etcd : Etcd::Client?
    private getter client_lock : Mutex { Mutex.new }

    def etcd(retry : Bool = true, max_elapsed_time : Time::Span = 30.seconds, & : Etcd::Client -> _)
      client_lock.synchronize do
        if retry
          Retriable.retry(
            base_interval: 1.milliseconds,
            randomise: 10.milliseconds,
            max_interval: 1.seconds,
            max_elapsed_time: max_elapsed_time,
            on_retry: ->(e : Exception, _a : Int32, _e : Time::Span, _n : Time::Span) { Log.warn(exception: e) { "when calling etcd" } }
          ) do
            run_etcd do |client|
              yield client
            end
          end
        else
          run_etcd do |client|
            yield client
          end
        end
      end
    end

    private def run_etcd
      client = @etcd || HoundDog.etcd_client
      begin
        yield client
      rescue exception
        @etcd.try &.close
        @etcd = nil
        raise exception
      end
    end

    private getter node_key : String

    def initialize(
      @service : String,
      @name : String,
      uri : URI | String
    )
      @uri = uri.is_a?(String) ? URI.parse(uri) : uri
      @node = {name: name, uri: @uri}
      @node_key = "#{self.class.namespace}/#{service}/#{name}"
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

      Log.debug { "existing value for #{node_key}: #{kv.value}" } unless kv.nil?

      # Check for key-value existence
      ttl = if kv && kv.key == node_key && kv.value == uri.to_s && (existing_id = kv.lease)
              @lease_id = existing_id

              Log.debug { "reusing existing lease from previous registration: #{lease_id}" }

              # Renew lease if key-value and lease present
              ttl
            else
              new_lease(ttl)
            end

      Log.debug { "registered lease #{lease_id} for #{node_key}" }

      begin
        lease_id.try { |id| registration_channel.send(id) }
      rescue Channel::ClosedError
      end

      keep_alive(ttl)
    end

    # Unregister current service node
    #
    def unregister
      return unless (id = lease_id)
      lease_deleted = etcd &.lease.revoke(id)

      raise "Failed to unregister #{node} under #{service}" unless lease_deleted
      registration_channel.close unless registration_channel.closed?
      @lease_id = nil
    end

    # Service Namespace
    ###########################################################################

    # List nodes under a service namespace
    #
    def self.nodes(service, client : Etcd::Client? = nil) : Array(Node)
      namespace_key = "#{namespace}/#{service}/"
      range = client ? client.kv.range_prefix(namespace_key).kvs : HoundDog.etcd_client &.kv.range_prefix(namespace_key).kvs

      range.compact_map do |n|
        # Parse an Etcd KV into a Node
        n.value.try { |v| self.node(key: n.key, value: v) }
      end
    end

    # :ditto:
    def nodes : Array(Node)
      etcd do |client|
        self.class.nodes(service, client)
      end
    end

    # List available services
    #
    def self.services(client : Etcd::Client? = nil)
      kvs = (etcd = client) ? etcd.kv.range_prefix(@@namespace).kvs : HoundDog.etcd_client &.kv.range_prefix(@@namespace).kvs
      kvs.compact_map(&.key.split('/')[1]?).uniq!
    end

    # :ditto:
    def services
      etcd do |client|
        self.class.services(client)
      end
    end

    # Remove all keys beneath namespace
    #
    def self.clear_namespace(client : Etcd::Client? = nil)
      (etcd = client) ? etcd.kv.delete_prefix(@@namespace) : HoundDog.etcd_client &.kv.delete_prefix(@@namespace)
    end

    # :ditto:
    def clear_namespace
      etcd do |client|
        self.class.clear_namespace(client)
      end
    end

    # Monitoring
    ###########################################################################

    # Start monitoring the service namespace
    #
    def monitor(&callback : Event ->)
      unmonitor unless watchfeed.nil?
      self.watchfeed = Service.watch(@service, &callback)
    end

    # Stop monitoring the service namespace
    #
    def unmonitor
      self.watchfeed.try &.stop
      self.watchfeed = nil
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

    # Synchronous interface
    def self.watch(service, &block : Event ->)
      prefix = "#{@@namespace}/#{service}"
      client = HoundDog.etcd_client
      begin
        client.watch.watch_prefix(prefix) do |events|
          events.each { |event| block.call self.parse_event(event) }
        end
      ensure
        client.close
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
      retry_interval = ttl // 3
      loop do
        begin
          id = lease_id
          if id.nil?
            Log.info { "in keep_alive: stopped keep_alive" }
            break
          end

          start = Time.monotonic
          new_ttl = Tasker.instance.in(retry_interval.seconds) do
            elapsed = Time.monotonic - start
            if elapsed > ttl.seconds
              # Attempt to renew if lease has expired
              Log.warn { "keep_alive: lost lease #{id} for #{node_key}" }
              new_lease(ttl)
            else
              # Otherwise keep alive lease
              renewed_ttl = etcd &.lease.keep_alive(id)
              if renewed_ttl.nil? && !lease_id.nil?
                Log.warn { "keep_alive: lost lease #{id} for #{node_key}" }
                new_lease(ttl)
              else
                renewed_ttl
              end
            end
          end.get
          ttl = new_ttl unless new_ttl.nil?
          retry_interval = ttl // 3
        rescue error
          Log.error(exception: error) { "keep_alive: unexpected error maintaining lease" }
        end
      end
    end

    private getter lease_lock = Mutex.new

    protected def new_lease(ttl : Int64 = HoundDog.settings.etcd_ttl)
      lease_lock.synchronize do
        # Revoke existing lease
        if id = lease_id
          begin
            etcd &.lease.revoke(id)
          rescue e
            Log.warn(exception: e) { "failed to revoke lease when requesting a new one" }
          end
        end

        # Secure and maintain lease from etcd
        lease = etcd &.lease.grant(ttl)
        Log.debug { "granted lease for #{node_key}: #{lease.id} with ttl of #{lease.ttl}" }
        Retriable.retry(
          base_interval: 1.milliseconds,
          randomise: 10.milliseconds,
          max_interval: 1.seconds,
          max_elapsed_time: ttl.seconds,
        ) do
          # Register service under namespace
          if etcd(&.kv.put(node_key, uri, lease: lease.id)).nil?
            raise "failed to register #{@node} under #{@service}"
          end
        end

        @lease_id = lease.id

        lease.ttl
      end
    end
  end
end
