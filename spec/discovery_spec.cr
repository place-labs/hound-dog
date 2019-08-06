require "./helper"

module HoundDog
  describe Discovery do
    etcd_host = ENV["ETCD_HOST"]? || "127.0.0.1"
    etcd_port = (ENV["ETCD_PORT"]? || 2379).to_u16
    etcd_ttl = (ENV["ETCD_TTL"]? || 5).to_i64
    client = Etcd.new(etcd_host, etcd_port, etcd_ttl)
    namespace = HoundDog.settings.service_namespace

    Spec.before_each do
      client.delete_prefix namespace
    end

    it "self-registers with etcd" do
      service = "api"
      port : UInt16 = 42

      node = Service::Node.new(
        ip: "foo",
        port: port,
      )

      d = Discovery.new(
        service: service,
        ip: node[:ip],
        port: node[:port],
      )

      d.should_not be_nil
      Service.nodes("test").should eq [node]
    end

    it "initialises rendezvous hash" do
      service = "api"
      port : UInt16 = 42

      values = [
        Service::Node.new(ip: "foo",
          port: port,
        ),
        Service::Node.new(ip: "bar",
          port: port,
        ),
        Service::Node.new(ip: "foot",
          port: port,
        ),
        Service::Node.new(ip: "bath",
          port: port,
        ),
      ]

      # Create some services
      lease = client.lease_grant etcd_ttl
      values.each do |v|
        key = "#{namespace}/#{service}/#{v[:ip]}"
        value = Service.key_value(v)
        client.put(key, value, lease: lease[:id])
      end

      discovery = Discovery.new(
        service: service,
        ip: "tree",
        port: port,
      )

      # Local nodes should match remote notes after initialisation
      Service.nodes(service).should eq discovery.nodes
    end

    it "transparently handles service registration" do
      service = "api"
      port : UInt16 = 42

      new_node = Service::Node.new(
        ip: "foo",
        port: port,
      )

      discovery = Discovery.new(
        service: service,
        ip: "tree",
        port: port,
      )

      # Create a service
      lease = client.lease_grant etcd_ttl
      key = "#{namespace}/#{service}/#{new_node[:ip]}"

      value = Service.key_value(new_node)
      client.put(key, value, lease: lease[:id])

      sleep 2

      # Local nodes should match remote notes after initialisation
      Service.nodes(service).should eq discovery.nodes
    end

    it "transparently handles service removal" do
      service = "api"
      port : UInt16 = 42

      new_node = Service::Node.new(
        ip: "foo",
        port: port,
      )

      # Create a service
      lease = client.lease_grant etcd_ttl
      key = "#{namespace}/#{service}/#{new_node[:ip]}"
      value = Service.key_value(new_node)
      client.put(key, value, lease: lease[:id])

      discovery = Discovery.new(
        service: service,
        ip: "tree",
        port: port,
      )
      sleep 1

      # Local nodes should match remote notes after initialisation
      discovery.nodes.should eq [new_node]
      Service.nodes(service).should eq discovery.nodes

      client.delete(key)
      sleep 1

      # Local nodes should match remote notes after a delete
      discovery.nodes.should be_empty
      Service.nodes(service).should be_empty
    end
  end
end
