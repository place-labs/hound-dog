require "../models/etcd_client"
require "tasker"

class EtcdController < Application
  base "/etcd"

  private HOST              = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
  private PORT              = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
  private TTL               = (ENV["ACA_ETCD_TTL"]? || 60).to_i64
  private CLUSTER_NAMESPACE = ENV["ACA_ETCD_CLUSTER_NAMESPACE"]? || "service/engine/servers"
  private LEASE_HEARTBEAT   = (ENV["ACA_ETCD_LEASE_HEARTBEAT"]? || 2).to_i

  CLIENT  = EtcdClient.new(HOST, PORT, TTL)
  SOCKETS = [] of HTTP::WebSocket

  get "/version", :version do
    render json: {
      version: CLIENT.version,
    }
  end

  get "/services", :services do
    range = CLIENT.range_prefix "service"
    services = range.map { |r| r[:key].split('/')[1] }
    p services
    render json: {
      services: services.uniq,
    }
  end

  # Register with local instance of etcd
  # service
  # ip          ip of service
  # port        port of service
  ws "/register", :register do |socket|
    service_param, ip, port = params["service"]?, params["ip"]?, params["port"]?
    render :bad_request, text: %("service", "ip" and "port" param required) unless service_param && ip && port

    lease = CLIENT.lease_grant TTL

    services = service_param.split(',')
    key = {CLUSTER_NAMESPACE, services[0], ip}.join("/")
    value = {ip, port}.join(":")

    key_set = CLIENT.put(key, value)
    render :internal_server_error, text: "failed to register service" unless key_set

    keepalive_loop = schedule.every(LEASE_HEARTBEAT.seconds) { CLIENT.lease_keep_alive lease[:id] }
    watch = CLIENT.watch_prefix(CLUSTER_NAMESPACE)

    socket.on_close do
      SOCKETS.delete socket
      keepalive_loop.cancel
    end
  end

  # Subscribe to etcd events over keys
  ws "/monitor", :monitor do |socket|
    SOCKETS << socket
    service_param = params["service"]?
    render :bad_request, text: %("service" param required) unless service_param

    services = service_param.split(',')
    watch = CLIENT.watch_prefix(CLUSTER_NAMESPACE)
    socket.on_close do
      SOCKETS.delete socket
    end
  end
end
