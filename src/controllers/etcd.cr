require "../models/etcd_client"
require "tasker"

class EtcdController < Application
  base "/etcd"

  private HOST              = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
  private PORT              = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
  private TTL               = (ENV["ACA_ETCD_TTL"]? || 60).to_i64
  private SERVICE_NAMESPACE = ENV["ACA_ETCD_SERVICE_NAMESPACE"]? || "service"
  private EVENT_NAMESPACE   = ENV["ACA_ETCD_EVENT_NAMESPACE"]? || "event"
  private LEASE_HEARTBEAT   = (ENV["ACA_ETCD_LEASE_HEARTBEAT"]? || 2).to_i

  CLIENT          = EtcdClient.new(HOST, PORT, TTL)
  EVENT_LISTENERS = {} of String => Set(HTTP::WebSocket)
  SOCKETS         = [] of HTTP::WebSocket

  settings.logger.level = Logger::DEBUG
  def self.logger; settings.logger; end

  self.watch_namespace SERVICE_NAMESPACE do |event|
    process_service_event event
  end

  self.watch_namespace EVENT_NAMESPACE, filters: [WatchFilter::NODELETE] do |event|
    process_custom_event event
  end

  def initialize(@context : HTTP::Server::Context, @action_name = :index)
    super
    logger.level = Logger::DEBUG
  end

  # Get etcd version response
  get "/version", :version do
    render json: {
      version: CLIENT.version,
    }
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
    render :bad_request, text: %(Specify services or broadcast) unless body.broadcast || !services.empty?

    event = {
      type: body.event_type,
      body: body.event_body,
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
  end

  # List nodes under a service namespace
  def service_nodes(service)
    namespace = "service/#{service}/"
    range = CLIENT.range_prefix namespace
    range.map do |n|
      ip, port = n[:value].split(':')
      {
        ip:   ip,
        port: port,
      }
    end
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
    render json: service_nodes params["service"]
  end

  # Register with local instance of etcd, receive node events over websocket
  # service     service namespace to register beneath             String
  # ip          ip of service                                     String
  # port        port of service                                   Int16
  # monitor     (optional) receive events of additional services  Array(String)
  ws "/register", :register do |socket|
    service, ip, port = params["service"]?, params["ip"]?, params["port"]?
    render :bad_request, text: %("service", "ip" and "port" param required) unless service && ip && port

    # Secure lease
    lease = CLIENT.lease_grant TTL
    keepalive_loop = schedule.every(LEASE_HEARTBEAT.seconds) { CLIENT.lease_keep_alive lease[:id] }
    keepalive_loop.each do |_|
      keepalive_loop.cancel if socket.closed?
    end

    # Add socket as listener to events for services
    monitor = params["monitor"]? ? params["monitor"].split(',') : [] of String
    service_subscriptions = monitor << service
    socket.on_close do
      remove_event_listener(socket, service_subscriptions)
    end

    # Register service under namespace
    key = {SERVICE_NAMESPACE, service, ip}.join("/")
    value = "#{ip}:#{port}"
    key_set = CLIENT.put(key, value, lease: lease[:id])
    render :internal_server_error, text: "failed to register service" unless key_set

    delegate_event_listener(socket, service_subscriptions)
  end

  # Subscribe to etcd events over keys
  ws "/monitor", :monitor do |socket|
    render :bad_request, text: %("monitor" param required) unless params["monitor"]?

    service_subscriptions = params["monitor"].split(',')

    delegate_event_listener(socket, service_subscriptions)
    socket.on_close do
      remove_event_listener(socket, service_subscriptions)
    end
  end

  # Spawn a thread to listen to a namespace for events
  def self.watch_namespace(namespace, **opts, &block : EtcdWatchEvent -> Void)
    spawn do
      logger.debug "watching #{namespace}"
      CLIENT.watch_prefix namespace, **opts do |events|
        events.each { |event| block.call event }
      end
    end
  rescue error
    logger.debug "in watch_namespace #{namespace}\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
    sleep 1 # Delay retry to prevent hammering etcd
    watch_namespace namespace, **opts, &block
  end

  def parse_namespace(key)

  end

  def self.process_custom_event(event)
    self.delegate_message message: event.to_json, broadcast: true
  end

  def self.process_service_event(event)
    # namespace = parse_namespace(event.kv.key)
    # logger.debug event
    # p event.kv
    # key = event.kv.key
    # event
    # service = key.split('/')[1]
    # nodes = service_nodes service
    self.delegate_message message: event.to_json, broadcast: true
  end

  # Send message to listeners on each service
  # message   rendered event message                    String
  # services  array of services to delegate message to  Array(String)
  # broadcast send message to all listeners             Bool
  def self.delegate_message(message, services = [] of String, broadcast = false)
    if broadcast
      SOCKETS.each do |socket|
        socket.send message
      end
    else
      # TODO: ensure message sent to a socket only once
      services.each do |service|
        EVENT_LISTENERS[service].each do |socket|
          socket.send message
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
