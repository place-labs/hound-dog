require "uuid"
require "./helper"

module HoundDog
  describe Service do
    etcd_host = ENV["ETCD_HOST"]? || "127.0.0.1"
    etcd_port = (ENV["ETCD_PORT"]? || 2379).to_i
    etcd_ttl = (ENV["ETCD_TTL"]? || 30).to_i64
    client = Etcd.client(etcd_host, etcd_port)

    Spec.before_each do
      client.kv.delete_prefix HoundDog.settings.service_namespace
    end

    it "discovers available services" do
      lease = client.lease.grant etcd_ttl

      key0, value0 = "service/api/foo", "http://foo:42"
      key1, value1 = "service/api/bar", "http://bar:42"
      key2, value2 = "service/engine/foo", "http://foot:42"
      key3, value3 = "service/engine/bar", "http://bath:42"

      client.kv.put(key0, value0, lease: lease[:id])
      client.kv.put(key1, value1, lease: lease[:id])
      client.kv.put(key2, value2, lease: lease[:id])
      client.kv.put(key3, value3, lease: lease[:id])

      Service.services.sort.should eq ["api", "engine"]
    end

    it "lists services beneath given namespace" do
      lease = client.lease.grant etcd_ttl

      key0, value0 = "service/api/foot", "http://foot:42"
      key1, value1 = "service/api/bath", "http://bath:42"
      key2, value2 = "service/engine/foo", "http://foo:42"

      client.kv.put(key0, value0, lease: lease[:id])
      client.kv.put(key1, value1, lease: lease[:id])
      client.kv.put(key2, value2, lease: lease[:id])

      expected = [
        {name: "bath", uri: URI.parse("http://bath:42")},
        {name: "foot", uri: URI.parse("http://foot:42")},
      ]

      Service.nodes("api").should eq expected
    end

    describe "#register" do
      it "registers a service" do
        service = "carrots"
        name = UUID.random.to_s
        uri = URI.parse("http://127.0.0.1:4242")
        ttl : Int64 = 1

        node = {
          name: name,
          uri:  uri,
        }

        registration = Service.new(service: service, name: name, uri: uri)

        spawn(same_thread: true) { registration.register(ttl: ttl) }

        # Wait for registration
        sleep 0.2

        # Check that service registered
        Service.nodes(service).should contain node

        registration.unregister

        registration.registered?.should be_false

        sleep ttl

        # Check the service is no longer present in etcd
        Service.nodes(service).should_not contain node
      end

      it "monitors a service" do
        service = "potato"
        node0_name = "dub"
        node0_uri = "http://127.0.0.1:4242"
        node1_name = "tub"
        node1_uri = "http://0.0.0.0:4242"
        ttl : Int64 = 1

        node0 = {
          name: node0_name,
          uri:  URI.parse(node0_uri),
        }

        node1 = {
          name: node1_name,
          uri:  URI.parse(node1_uri),
        }

        subscription0 = Service.new(service: service, name: node0_name, uri: node0_uri)
        subscription1 = Service.new(service: service, name: node1_name, uri: node1_uri)

        channel = Channel(Service::Event).new

        # Create a watchfeed for service
        watchfeed0 = subscription0.monitor do |event|
          channel.send(event)
        end

        # Start monitoring the namespace
        spawn(same_thread: true) { watchfeed0.start }

        sleep 0.2

        # Register another node
        spawn(same_thread: true) do
          subscription1.register(ttl: ttl)
        end

        sleep 0.2

        # Check callbacks are received
        channel.receive[:type].should eq Etcd::Model::WatchEvent::Type::PUT

        # Check that only node1 service registered
        Service.nodes(service).should contain node1

        subscription1.unregister
        subscription1.registered?.should be_false

        sleep ttl

        # Check the service is no longer present in etcd
        Service.nodes(service).should_not contain node1

        # Check callbacks are received
        channel.receive[:type].should eq Etcd::Model::WatchEvent::Type::DELETE

        subscription0.unregister
        subscription0.registered?.should be_false

        Service.clear_namespace

        # Check the service is no longer present in etcd
        Service.nodes(service).should_not contain node0
      end
    end
  end
end
