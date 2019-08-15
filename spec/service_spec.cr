require "./helper"

module HoundDog
  describe Service do
    etcd_host = ENV["eTCD_HOST"]? || "127.0.0.1"
    etcd_port = (ENV["ETCD_PORt"]? || 2379).to_u16
    etcd_ttl = (ENV["ETCD_TTL"]? || 5).to_i64
    client = HoundDog::Etcd.new(etcd_host, etcd_port, etcd_ttl)

    Spec.before_each do
      client.delete_prefix HoundDog.settings.service_namespace
    end

    it "discovers available services" do
      lease = client.lease_grant etcd_ttl

      key0, value0 = "service/api/foo", "foo:42"
      key1, value1 = "service/api/bar", "bar:42"
      key2, value2 = "service/engine/foo", "foot:42"
      key3, value3 = "service/engine/bar", "bath:42"

      client.put(key0, value0, lease: lease[:id])
      client.put(key1, value1, lease: lease[:id])
      client.put(key2, value2, lease: lease[:id])
      client.put(key3, value3, lease: lease[:id])

      Service.services.sort.should eq ["api", "engine"]
    end

    it "lists services beneath given namespace" do
      lease = client.lease_grant etcd_ttl

      key0, value0 = "service/api/foo", "foot:42"
      key1, value1 = "service/api/bar", "bath:42"
      key2, value2 = "service/engine/foo", "foo:42"

      client.put(key0, value0, lease: lease[:id])
      client.put(key1, value1, lease: lease[:id])
      client.put(key2, value2, lease: lease[:id])

      expected = [
        {ip: "bath", port: 42},
        {ip: "foot", port: 42},
      ]

      Service.nodes("api").should eq expected
    end

    describe "#register" do
      it "registers a service" do
        service = "carrots"
        ip = "127.0.0.1"
        port : UInt16 = 4242
        ttl : Int64 = 5

        node = {
          ip:   ip,
          port: port,
        }

        registration = Service.new(service: service, node: node)

        spawn { registration.register(ttl: ttl) }

        # Wait for registration
        sleep 0.5

        # Check that service registered
        Service.nodes(service).should contain node

        registration.unregister

        registration.registered.should be_false

        sleep ttl

        # Check the service is no longer present in etcd
        Service.nodes(service).should_not contain node
      end

      it "monitors a service" do
        service = "potato"
        ip0 = "127.0.0.1"
        ip1 = "0.0.0.0"
        port : UInt16 = 4242
        ttl : Int64 = 5

        node0 = {
          ip:   ip0,
          port: port,
        }

        node1 = {
          ip:   ip1,
          port: port,
        }

        subscription0 = Service.new(service: service, node: node0)
        subscription1 = Service.new(service: service, node: node1)

        channel = Channel(Service::Event).new

        # Create a watchfeed for service
        watchfeed0 = subscription0.monitor do |event|
          channel.send(event)
        end

        # Start monitoring the namespace
        spawn { watchfeed0.start }

        sleep 1

        # Register another node
        spawn do
          subscription1.register(ttl: ttl)
        end

        sleep 1

        # Check callbacks are received
        channel.receive[:type].should eq Etcd::WatchEvent::Type::PUT

        # Check that only node1 service registered
        Service.nodes(service).should contain node1

        subscription1.unregister
        subscription1.registered.should be_false

        sleep ttl

        # Check the service is no longer present in etcd
        Service.nodes(service).should_not contain node1

        # Check callbacks are received
        channel.receive[:type].should eq Etcd::WatchEvent::Type::DELETE

        subscription0.unregister
        subscription0.registered.should be_false

        sleep ttl

        # Check the service is no longer present in etcd
        Service.nodes(service).should_not contain node0
      end
    end
  end
end
