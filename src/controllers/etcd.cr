require "../models/etcd_client"
require "tasker"

class EtcdController < Application
  base "/etcd"

  private ETCD_HOST              = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
  private ETCD_PORT              = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
  private ETCD_TTL               = (ENV["ACA_ETCD_TTL"]? || 60).to_i64
  private ETCD_CLUSTER_NAMESPACE = ENV["ACA_CLUSTER_NAMESPACE"]? || "engine/servers"

  ETCD_CLIENT = EtcdClient.new(ETCD_HOST, ETCD_PORT, ETCD_TTL)
  SOCKETS     = [] of HTTP::WebSocket

  get "/version", :version do
    render json: {
      version: ETCD_CLIENT.version,
    }
  end

  def renew(lease, ttl)
  end

  # Register with local instance of etcd
  # service
  # ip          ip of service
  # port        port of service
  ws "/register", :register do |socket|
    service_param, ip, port = params["service"]?, params["ip"]?, params["port"]?
    render :bad_request, text: %("service", "ip" and "port" param required) unless service_param && ip && port

    lease = ETCD_CLIENT.lease_grant ETCD_TTL

    services = service_param.split(',')
    key = {ETCD_CLUSTER_NAMESPACE, services[0], ip}.join("/")
    value = {ip, port}.join(":")

    key_set = ETCD_CLIENT.put(key, value)
    render :internal_server_error, text: "failed to register service" unless key_set

    watch = ETCD_CLIENT.watch_prefix(ETCD_CLUSTER_NAMESPACE)

    socket.on_close do
      SOCKETS.delete socket
    end
  end

  # Subscribe to etcd events over keys
  ws "/monitor", :monitor do |socket|
    SOCKETS << socket
    service_param = params["service"]?
    render :bad_request, text: %("service" param required) unless service_param

    services = service_param.split(',')
    watch = ETCD_CLIENT.watch_prefix(ETCD_CLUSTER_NAMESPACE)
    socket.on_close do
      SOCKETS.delete socket
    end
  end

  post "/unregister", :unregister do
    service = params["service"]?
    render :bad_request, text: %("service" param required) unless service
    ETCD_CLIENT.delete service
  end
end
