require "habitat"

module HoundDog
  Habitat.create do
    # Service Discovery Configuration
    ###########################################################################
    setting service_namespace : String = ENV["HD_SERVICE_NAMESPACE"]? || "service"

    # ETCD Configuration
    ###########################################################################
    setting etcd_host : String = ENV["ETCD_HOST"]? || "127.0.0.1"
    setting etcd_port : Int32 = (ENV["ETCD_PORT"]? || 2379).to_i
    setting etcd_ttl : Int64 = (ENV["ETCD_TTL"]? || 15).to_i64
  end
end
