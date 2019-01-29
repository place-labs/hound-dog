require "../models/etcd_client"

class EtcdController < Application
  base "/etcd"

  private HOST              = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
  private PORT              = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
  private TTL               = (ENV["ACA_ETCD_TTL"]? || 60).to_i64
  private SERVICE_NAMESPACE = ENV["ACA_ETCD_SERVICE_NAMESPACE"]? || "service"
  private EVENT_NAMESPACE   = ENV["ACA_ETCD_EVENT_NAMESPACE"]? || "event"
  private LEASE_HEARTBEAT   = (ENV["ACA_ETCD_LEASE_HEARTBEAT"]? || 2).to_i

  private CLIENT = EtcdClient.new(HOST, PORT, TTL)
  # Map of service namespace to event subscribers
  private EVENT_LISTENERS = Hash(String, Set(HTTP::WebSocket)).new { |h, k| h[k] = Set(HTTP::WebSocket).new }
  private SOCKETS         = [] of HTTP::WebSocket

  settings.logger.level = Logger::DEBUG

  def self.logger
    settings.logger
  end

  self.watch_namespace SERVICE_NAMESPACE do |event|
    process_service_event event
  end

  self.watch_namespace EVENT_NAMESPACE, filters: [WatchFilter::NODELETE] do |event|
    process_custom_event event
  end

  def initialize(@context : HTTP::Server::Context, @action_name = :index, @__head_request__ = false)
    super
    logger.level = Logger::DEBUG
  end

  # Get etcd version response
  get "/version", :version do
    render json: {
      version: CLIENT.version,
    }
  end

  # Get leader id and current etcd node member_id
  get "/leader", :version do
    status = CLIENT.status
    render json: {
      leader:    status[:leader],
      member_id: status[:member_id],
    }
  end

  # List active services.
  get "/services", :services do
    range = CLIENT.range_prefix "service"
    services = range.map { |r| r[:key].split('/')[1] }

    render json: {
      services: services.uniq,
    }
  end

  # List active service nodes beneath a service namespace.
  get "/services/:service", :service do
    render json: EtcdController.service_nodes params["service"]
  end

  # List nodes under a service namespace
  def self.service_nodes(service)
    namespace = "service/#{service}/"
    range = CLIENT.range_prefix namespace
    range.map do |n|
      ip, port = n[:value].split(':')
      {
        ip:   ip,
        port: port.to_u32,
      }
    end
  end

  # Register with local instance of etcd, receive node events over websocket
  # service     service namespace to register beneath             String
  # ip          ip of service                                     String
  # port        port of service                                   Int16
  # monitor     (optional) receive events of additional services  Array(String)
  ws "/register", :register do |socket|
    service, ip, port = query_params["service"]?, query_params["ip"]?, query_params["port"]?
    raise %("service", "ip" and "port" param required) unless service && ip && port

    # Add socket as listener to events for services
    monitor = params["monitor"]? ? params["monitor"].split(',') : [] of String
    service_subscriptions = monitor << service

    # Secure and maintain lease
    lease = CLIENT.lease_grant TTL
    spawn keep_alive(lease[:id], lease[:ttl], socket)

    # Register service under namespace
    key = {SERVICE_NAMESPACE, service, ip}.join("/")
    value = "#{ip}:#{port}"
    key_set = CLIENT.put(key, value, lease: lease[:id])
    render :internal_server_error, text: "failed to register service" unless key_set

    delegate_event_listener(socket, service_subscriptions)
    socket.on_close do
      remove_event_listener(socket, service_subscriptions)
      socket.close # socket.closed not set automatically
    end
    head :ok
  rescue error
    logger.debug "in register\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end

  # Subscribe to etcd events over keys
  ws "/monitor", :monitor do |socket|
    monitor = query_params["monitor"]?
    raise %("monitor" param required) unless monitor
    service_subscriptions = monitor.split(',')
    delegate_event_listener(socket, service_subscriptions)
    socket.on_close do
      remove_event_listener(socket, service_subscriptions)
    end
    head :ok
  rescue error
    logger.debug "in monitor\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end

  # Method to defer renewal of lease with a dynamic TTL
  def keep_alive(id, ttl, socket)
    retry_interval = ttl // 2
    schedule.in(retry_interval.seconds) do
      renewed_ttl = CLIENT.lease_keep_alive id
      spawn keep_alive(id, renewed_ttl, socket) unless socket.closed?
    end
  end

  class CustomEventRequest < ActiveModel::Model
    include ActiveModel::Validation
    attribute event_type : String
    attribute event_body : String = ""
    attribute services : Array(String) = [] of String
    attribute broadcast : Bool = false
    validates :event_type, presence: true
  end

  # Send a custom event to a namespace or all listening instances
  # event_type   type of event                                     String
  # event_body   stringified event                                 String
  # broadcast    (optional) port of service                        Int16
  # services     (optional) receive events of additional services  Array(String)
  post "/event", :event do
    body = CustomEventRequest.from_json(request.body.not_nil!)
    render :bad_request, text: %(Missing "event_type" field in body) unless body.valid?
    services = body.services || [] of String

    # Even when defining defaults on an object in ActiveModel, you still need to nil check?
    render :bad_request, text: %(Specify services or broadcast) if !body.broadcast && services.empty?
    event = {
      event_type: body.event_type,
      event_body: body.event_body,
    }.to_json

    # Register event under respective namespace keys
    key_set = if body.broadcast
                CLIENT.put(EVENT_NAMESPACE, value: event)
              else
                keys_set = services.map do |service|
                  CLIENT.put("#{EVENT_NAMESPACE}/#{service}", value: event)
                end
                keys_set.all?
              end

    render :internal_server_error, text: "Failed to propagate event" unless key_set
    head :ok
  end

  alias WatchEvent = NamedTuple(
    event_type: String,
    namespace: String,
    service: String | Nil,
    key: String,
    value: String | Nil,
  )

  # Spawn a thread to listen to a namespace for events
  def self.watch_namespace(namespace, **opts, &block : WatchEvent -> Void)
    spawn do
      logger.debug "watching #{namespace}"
      CLIENT.watch_prefix namespace, **opts do |events|
        events.each { |event| block.call self.parse_event(event) }
      end
    end
  rescue error
    logger.debug "in watch_namespace #{namespace}\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
    sleep 1 # Delay retry to prevent hammering etcd
    watch_namespace namespace, **opts, &block
  end

  def self.parse_event(event) : WatchEvent
    kv = event.try(&.kv)
    key = kv.try(&.key)
    raise "Malformed event in parse_event" unless kv && key
    value = kv.try(&.value)
    # Event field is default empty on PUT events
    event_type = event.try(&.type) || "PUT"
    tokens = key.split('/')

    {
      event_type: event_type,
      namespace:  tokens[0],
      service:    tokens[1]?,
      key:        key,
      value:      value,
    }
  end

  def self.process_custom_event(event)
    service = event[:service]
    message = {
      namespace: event[:namespace],
      body:      event[:value],
    }.to_json

    if service
      self.delegate_message message: message, services: [service]
    else
      self.delegate_message message: message, broadcast: true
    end
  end

  def self.process_service_event(event)
    service = event[:service]
    raise "Undefined service in process service event" unless service

    message = {
      namespace: event[:namespace],
      body:      {
        event_type: event[:event_type],
        services:   self.service_nodes service,
      },
    }.to_json

    self.delegate_message message: message, services: [service]
  end

  # Send message to listeners on each service
  # message   rendered event message                    String
  # services  array of services to delegate message to  Array(String)
  # broadcast send message to all listeners             Bool
  def self.delegate_message(message, services = [] of String, broadcast = false)
    if broadcast
      SOCKETS.each do |socket|
        socket.send message unless socket.closed?
      end
    else
      # TODO: ensure message sent to a socket only once
      services.each do |service|
        EVENT_LISTENERS[service].each do |socket|
          socket.send message unless socket.closed?
        end
      end
    end
  end

  # Register socket as a listener for events for each namespace in services
  # socket    listening websocket                       HTTP::WebSocket
  # services  array of services to delegate socket to   Array(String)
  def delegate_event_listener(socket, services)
    services.each do |service|
      EVENT_LISTENERS[service].add socket
      SOCKETS.push socket
    end
  end

  # Remove socket as a listener for events for each namespace in services
  # socket    listening websocket                             HTTP::WebSocket
  # services  array of services to remove socket as listener  Array(String)
  def remove_event_listener(socket, services)
    services.each do |service|
      EVENT_LISTENERS[service].delete socket
      SOCKETS.delete socket
    end
  end
end
