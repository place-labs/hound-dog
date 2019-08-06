require "tasker"

require "./etcd"
require "./settings"

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

    # Flag for lease renewal
    @registered = false

    # so if a connection to etcd fails, retry, keep maintaining lease.
    # - retriable for etcd client.

    def initialize(@service : String, @node : Node, @logger : Logger = HoundDog.settings.logger)
    end

    def registered?
      !!(@unregister_callback)
    end

    # SO! we need
    # - register
    #   + stop renewing after registered variable set
    # - monitor

    # Registers a node under a service namespace, passing events under namespace to the callback
    # TODO
    #   - Check if key already present, with same value
    #     + grab lease, start renewing lease
    #     + monitor as normal
    #
    # Returns
    # - Callback to unregister
    # Effects
    # - Spawns a fiber to maintain the lease, TODO: stop fiber on conn close
    # - Sets node key under service namespace
    def register(ttl : Int64 = HoundDog.settings.etcd_ttl, &callback : Event ->) : Proc(Void)
      # Check if node is still registered
      unregister_callback = @unregister_callback
      return unregister_callback if unregister_callback

      # Secure and maintain lease from etcd
      lease = @@etcd.lease_grant ttl

      # Register service under namespace
      key = {@@namespace, @service, @node[:ip]}.join("/")
      value = Service.key_value(@node)
      key_set = @@etcd.put(key, value, lease: lease[:id])
      raise "Failed to register #{@node} under #{@service}" unless key_set

      channel = Service.watch_service(@service, &callback)
      raise "Failed to watch #{@service} namespace" unless channel

      # Types don't normalise from above check, have to cast.
      keep_alive(lease[:id], lease[:ttl], channel.as(Channel(Nil)))

      @unregister_callback = ->{ channel.as(Channel(Nil)).close unless channel.as(Channel(Nil)).closed? }
    end

    # Set once service node has been registered
    @unregister_callback : Proc(Void)?

    # unregister current services
    #
    def unregister
      if (unregister_callback = @unregister_callback)
        unregister_callback.call
        @unregister_callback = nil
      end
    end

    # List nodes under a service namespace
    #
    def self.nodes(service) : Array(Node)
      namespace = "#{@@namespace}/#{service}/"
      range = @@etcd.range_prefix namespace
      range.map do |n|
        self.node(n[:value])
      end
    end

    # List available services
    #
    def self.services
      @@etcd.range_prefix(@@namespace).compact_map do |r|
        r[:key].split('/')[1]?
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

    # Watching
    ########################################################################

    alias Event = NamedTuple(
      key: String,
      value: String?,
      type: Etcd::WatchEvent::Type,
      namespace: String,
      service: String?,
    )

    def self.watch_service(service, &block : Event ->)
      prefix = "#{@@namespace}/#{service}"
      @@etcd.watch_prefix(prefix) do |events|
        events.each { |event| block.call self.parse_event(event) }
      end
    end

    def self.parse_event(event : Etcd::WatchEvent) : Event
      kv = event.kv.as(Etcd::WatchKV)
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
    protected def keep_alive(id : Int64, ttl : Int64, channel : Channel(Nil))
      retry_interval = ttl // 2
      Tasker.instance.in(retry_interval.seconds) do
        unless channel.closed?
          begin
            renewed_ttl = @@etcd.lease_keep_alive id
            spawn self.keep_alive(id, renewed_ttl, channel)
          rescue e
            @logger.error("in keep_alive: error=#{e.inspect_with_backtrace}")
          end
        end
      end
    end
  end
end
