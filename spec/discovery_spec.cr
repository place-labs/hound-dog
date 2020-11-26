require "./helper"

module HoundDog
  def self.put(client, namespace, service, name, value) : Service::Node
    node = Service::Node.new(
      name: name,
      uri: URI.parse(value),
    )
    key = "#{namespace}/#{service}/#{name}"
    client.kv.put(key, value)
    node
  end

  describe Discovery do
    etcd_ttl = (ENV["ETCD_TTL"]? || 1).to_i64
    client = HoundDog.etcd_client
    namespace = HoundDog.settings.service_namespace

    Spec.before_each do
      Service.clear_namespace
    end

    it "accepts a callback" do
      service = "api"

      change_chan = Channel(Array(Service::Node)).new
      register_chan = Channel(Array(Service::Node)).new

      discovery = Discovery.new(
        service: service,
        name: "rare",
        uri: "ssh://meme@internet",
        on_change: ->(changes : Array(Service::Node)) { change_chan.send changes }
      )

      Fiber.yield

      node0 = put(client, namespace, service, "bub", "http://127.0.0.1:4242")

      change_chan.receive.first.should eq node0

      spawn(same_thread: true) do
        discovery.register do |changes|
          register_chan.send changes
        end
      end

      node1 = put(client, namespace, service, "tub", "http://127.0.0.1:4242")

      change_chan.receive.should eq [node0, node1]
      register_chan.receive.should eq [node0, node1]

      discovery.unregister
      discovery.nodes.should eq [node0, node1]
    end

    it "#own_node?" do
      Service.clear_namespace

      service = "api"
      node_name = "bub"
      node_uri = "http://127.0.0.1:4242"

      discovery = Discovery.new(
        service: service,
        name: node_name,
        uri: node_uri,
      )

      spawn(same_thread: true) { discovery.register }

      sleep 0.2

      discovery.registration_channel.receive.should_not be_nil

      unless discovery.own_node?("hello")
        pp! discovery.nodes
      end

      discovery.own_node?("hello").should be_true
      discovery.unregister
      discovery.nodes.should be_empty
    end

    it "registers with etcd" do
      service = "api"
      node_name = "tub"
      node_uri = "http://127.0.0.1:4242"

      discovery = Discovery.new(
        service: service,
        name: node_name,
        uri: node_uri,
      )

      spawn(same_thread: true) { discovery.register }
      sleep 0.2
      discovery.registration_channel.receive.should_not be_nil

      # Ensure service registered
      discovery.nodes.should eq [discovery.node]
      Service.nodes(service).should eq [discovery.node]

      discovery.unregister
      sleep 0.2

      # Ensure service deregistered
      discovery.nodes.should be_empty
      Service.nodes(service).should be_empty
    end

    it "initialises rendezvous hash" do
      service = "api"
      node0_name = "foo"
      node0_uri = URI.parse("http://127.0.0.1:4242")
      node1_name = "tree"
      node1_uri = URI.parse("http://0.0.0.0:4000")
      ttl : Int64 = 1

      node0 = {
        name: node0_name,
        uri:  node0_uri,
      }

      node1 = {
        name: node1_name,
        uri:  node1_uri,
      }

      # Create some services
      lease = client.lease.grant etcd_ttl

      key = "#{namespace}/#{service}/#{node0_name}"
      client.kv.put(key, node0_uri, lease: lease[:id])

      discovery = Discovery.new(
        service: service,
        name: node1_name,
        uri: node1_uri,
      )

      spawn(same_thread: true) { discovery.register }
      sleep 0.2
      discovery.registration_channel.receive.should_not be_nil

      # Local nodes should match remote notes after initialisation

      discovery.nodes.should eq [node0, node1]
      Service.nodes(service).should eq [node0, node1]

      Service.nodes(service).should eq discovery.nodes
    end

    it "transparently handles service registration" do
      service = "api"
      new_node_name = "foo"
      new_node_uri = "http://127.0.0.1:4242"

      discovery = Discovery.new(
        service: service,
        name: new_node_name,
        uri: new_node_uri,
      )

      spawn(same_thread: true) { discovery.register }
      sleep 0.2
      discovery.registration_channel.receive.should_not be_nil

      # Create a service
      lease = client.lease.grant etcd_ttl
      key = "#{namespace}/#{service}/#{new_node_name}"

      client.kv.put(key, new_node_uri, lease: lease[:id])

      sleep 0.2

      etcd_nodes = Service.nodes(service).sort_by { |s| s[:name] }
      local_nodes = discovery.nodes.sort_by { |s| s[:name] }

      # Local nodes should match remote notes after initialisation
      etcd_nodes.should eq local_nodes
    end

    it "transparently handles service removal" do
      service = "api"

      discovery = Discovery.new(
        service: service,
        name: "tree",
        uri: "http://127.0.0.1:4242"
      )

      # Create a service
      lease = client.lease.grant etcd_ttl
      key = "#{namespace}/#{service}/#{discovery.name}"
      client.kv.put(key, discovery.uri.to_s, lease: lease[:id])

      spawn(same_thread: true) { discovery.register }
      sleep 0.2
      discovery.registration_channel.receive.should_not be_nil

      etcd_nodes = Service.nodes(service).sort_by { |s| s[:name] }
      local_nodes = discovery.nodes.sort_by { |s| s[:name] }

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
