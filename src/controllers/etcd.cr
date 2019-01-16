require "../models/etcd_client"
require "tasker"

class EtcdController < Application
  base "/etcd"

  private HOST              = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
  private PORT              = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
  private TTL               = (ENV["ACA_ETCD_TTL"]? || 60).to_i64
  private CLUSTER_NAMESPACE = ENV["ACA_ETCD_CLUSTER_NAMESPACE"]? || "service/engine"
  private LEASE_HEARTBEAT   = (ENV["ACA_ETCD_LEASE_HEARTBEAT"]? || 2).to_i

  CLIENT          = EtcdClient.new(HOST, PORT, TTL)
  EVENT_LISTENERS = {} of String => Set(HTTP::WebSocket)

  get "/version", :version do
    render json: {
      version: CLIENT.version,
    }
  end

  # Find active services.
  get "/services", :services do
    range = CLIENT.range_prefix "service"
    services = range.map { |r| r[:key].split('/')[1] }
    p services
    render json: {
      services: services.uniq,
    }
  end

  # TODO: list all service nodes beneath service namespaces
  get "/services/:service", :service do
    # TODO: parameter checking that service is offerred?
    service = params["service"]
    namespace = "service/#{service}/"
    range = CLIENT.range_prefix namespace
    service_nodes = range.map do |n|
      ip, port = n[:value].split(':')
      {
        ip:   ip,
        port: port,
      }
    end

    # TODO: Currently just node name. Return list of tuples containing ip and port?
    render json: service_nodes
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

    # Register service under namespace
    key = {CLUSTER_NAMESPACE, service, ip}.join("/")
    value = "#{ip}:#{port}"
    key_set = CLIENT.put(key, value)
    render :internal_server_error, text: "failed to register service" unless key_set

    # Add socket as listener to events for services
    monitor = params["monitor"]? ? params["monitor"].split(',') : [] of String
    service_subscriptions = monitor << service

    delegate_event_listener(socket, service_subscriptions)
    socket.on_close do
      remove_event_listener(socket, service_subscriptions)
      keepalive_loop.cancel
    end
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

  # Register socket as a listener for events for each namespace in services
  # socket    listening websocket                       HTTP::WebSocket
  # services  array of services to delegate socket to   Array(String)
  def delegate_event_listener(socket, services)
    services.each do |s|
      EVENT_LISTENERS[s].add socket
    end
  end

  # Remove socket as a listener for events for each namespace in services
  # socket    listening websocket                             HTTP::WebSocket
  # services  array of services to remove socket as listener  Array(String)
  def remove_event_listener(socket, services)
    services.each do |s|
      EVENT_LISTENERS[s].delete socket
    end
  end
end
