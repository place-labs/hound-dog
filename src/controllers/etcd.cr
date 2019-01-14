require "../models/etcd_client"

class EtcdController < Application
    base "/etcd"

    private ETCD_HOST = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
    private ETCD_PORT = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
    private ETCD_TTL = (ENV["ACA_ETCD_TTL"]? || 60).to_i

    ETCD_CLIENT = EtcdClient.new(ETCD_HOST, ETCD_PORT, ETCD_TTL)

    get "/version", :version do
        render json: {
            version: ETCD_CLIENT.version
        }
    end

end