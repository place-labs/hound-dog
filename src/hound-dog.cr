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

  # Yield etcd connection, closing after block returns
  def self.etcd_client
    client = etcd_client
    yield client ensure client.close
  end
end

require "./hound-dog/*"
