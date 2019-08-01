require "habitat"

module HoundDog
  Habitat.create do
    setting logger : Logger = Logger.new(STDOUT)

    # Service Discovery Configuration
    ###########################################################################
    setting service_namespace : String = ENV["HD_SERVICE_NAMESPACE"]? || "service"

    # ETCD Configuration
    ###########################################################################
    setting etcd_host : String = ENV["ETCD_HOST"]? || "127.0.0.1"
    setting etcd_port : UInt16 = (ENV["ETCD_PORT"]? || 2379).to_u16
    setting etcd_ttl : Int64 = (ENV["ETCD_TTL"]? || 20).to_i64
  end
end
