require "./helper"

module HoundDog
  describe Discovery do
    etcd_host = ENV["ETCD_HOST"]? || "127.0.0.1"
    etcd_port = (ENV["ETCD_PORT"]? || 2379).to_i
    etcd_ttl = (ENV["ETCD_TTL"]? || 1).to_i64
    client = Etcd.client(etcd_host, etcd_port)
    namespace = HoundDog.settings.service_namespace

    Spec.before_each do
      client.kv.delete_prefix namespace
    end

    it "accepts a callback" do
      service = "api"

      discovery = Discovery.new(
        service: service,
        ip: "bar",
        port: 41,
      )

      chan = Channel(Nil).new
      spawn(same_thread: true) do
        discovery.register do
          chan.send nil
        end
      end

      node0 = Service::Node.new(
        ip: "foo",
        port: 23,
      )

      key = "#{namespace}/#{service}/#{node0[:ip]}"
      value = Service.key_value(node0)
      client.kv.put(key, value)

      chan.receive.should be_nil
      discovery.unregister
      sleep 0.2
      discovery.nodes.should be_empty
    end

    it "#own_node?" do
      service = "api"
      port : Int32 = 42

      node = Service::Node.new(
        ip: "foo",
        port: port,
      )

      discovery = Discovery.new(
        service: service,
        ip: node[:ip],
        port: node[:port],
      )

      spawn(same_thread: true) { discovery.register }
      sleep 0.2

      discovery.own_node?("hello").should be_true
      discovery.unregister
      sleep 0.2
      discovery.nodes.should be_empty
    end

    it "registers with etcd" do
      service = "api"
      port : Int32 = 42

      node = Service::Node.new(
        ip: "foo",
        port: port,
      )

      discovery = Discovery.new(
        service: service,
        ip: node[:ip],
        port: node[:port],
      )

      spawn(same_thread: true) { discovery.register }
      sleep 0.2

      # Ensure service registered
      discovery.nodes.should eq [node]
      Service.nodes(service).should eq [node]

      discovery.unregister
      sleep 0.2

      # Ensure service deregistered
      discovery.nodes.should be_empty
      Service.nodes(service).should be_empty
    end

    it "initialises rendezvous hash" do
      service = "api"
      port : Int32 = 42

      node0 = Service::Node.new(ip: "foo", port: port)
      node1 = Service::Node.new(ip: "tree", port: port)

      # Create some services
      lease = client.lease.grant etcd_ttl

      key = "#{namespace}/#{service}/#{node0[:ip]}"
      value = Service.key_value(node0)
      client.kv.put(key, value, lease: lease[:id])

      discovery = Discovery.new(
        service: service,
        ip: node1[:ip],
        port: node1[:port],
      )

      spawn(same_thread: true) { discovery.register }
      sleep 0.2

      # Local nodes should match remote notes after initialisation

      discovery.nodes.should eq [node0, node1]
      Service.nodes(service).should eq [node0, node1]

      Service.nodes(service).should eq discovery.nodes
    end

    it "transparently handles service registration" do
      service = "api"
      port : Int32 = 42

      new_node = Service::Node.new(
        ip: "foo",
        port: port,
      )

      discovery = Discovery.new(
        service: service,
        ip: "tree",
        port: port,
      )

      spawn(same_thread: true) { discovery.register }
      Fiber.yield

      # Create a service
      lease = client.lease.grant etcd_ttl
      key = "#{namespace}/#{service}/#{new_node[:ip]}"

      value = Service.key_value(new_node)
      client.kv.put(key, value, lease: lease[:id])

      sleep 0.2

      etcd_nodes = Service.nodes(service).sort_by { |s| s[:ip] }
      local_nodes = discovery.nodes.sort_by { |s| s[:ip] }

      # Local nodes should match remote notes after initialisation
      etcd_nodes.should eq local_nodes
    end

    it "transparently handles service removal" do
      service = "api"
      port : Int32 = 42

      new_node = Service::Node.new(
        ip: "foo",
        port: port,
      )

      # Create a service
      lease = client.lease.grant etcd_ttl
      key = "#{namespace}/#{service}/#{new_node[:ip]}"
      value = Service.key_value(new_node)
      client.kv.put(key, value, lease: lease[:id])

      discovery = Discovery.new(
        service: service,
        ip: "tree",
        port: port,
      )

      spawn(same_thread: true) { discovery.register }
      sleep 0.2

      etcd_nodes = Service.nodes(service).sort_by { |s| s[:ip] }
      local_nodes = discovery.nodes.sort_by { |s| s[:ip] }

      # Local nodes should match remote notes after initialisation
      etcd_nodes.should eq local_nodes

      client.kv.delete(key)
      discovery.unregister

      sleep 0.2

      # Local nodes should match remote notes after a delete
      discovery.nodes.should be_empty
      Service.nodes(service).should be_empty
    end
  end
end
