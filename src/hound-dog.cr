require "log_helper"

# Service discovery information
module HoundDog
  Log = ::Log.for(self)

  # Single connection
  def self.etcd_client
    Etcd.client(
      host: HoundDog.settings.etcd_host,
      port: HoundDog.settings.etcd_port,
    )
  end
end

require "./hound-dog/*"
