require "./spec_helper"
require "json"
require "tasker"

describe EtcdController do
  etcd_host = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
  etcd_port = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
  etcd_ttl = (ENV["ACA_ETCD_TTL"]? || 5).to_i64
  client = EtcdClient.new(etcd_host, etcd_port, etcd_ttl)

  with_server do
    Spec.before_each do
      client.delete_prefix "service"
    end

    it "performs leader election" do
      response = curl("GET", "/etcd/leader")
      body = JSON.parse response.body
      leader = body["leader"]
      member_id = body["member_id"]

      # single member of etcd cluster
      leader.should eq member_id
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

      response = curl("GET", "/etcd/services")
      body = JSON.parse(response.body)
      services = body["services"].as_a.map { |v| v.as_s }

      services_present = {"api", "engine"}.all? do |service|
        services.includes? service
      end

      services_present.should be_true
    end

    it "lists services beneath given namespace" do
      lease = client.lease_grant etcd_ttl
      key0, value0 = "service/api/foo", "foot:42"
      key1, value1 = "service/api/bar", "bath:42"
      key2, value2 = "service/engine/foo", "foo:42"
      client.put(key0, value0, lease: lease[:id])
      client.put(key1, value1, lease: lease[:id])
      client.put(key2, value2, lease: lease[:id])

      response = curl("GET", "/etcd/services/api")
      body = JSON.parse(response.body)
      services = body.as_a.map { |v| {ip: v["ip"].as_s, port: v["port"].as_i} }

      expected = [
        {ip: "bath", port: 42},
        {ip: "foot", port: 42},
      ]
      services.sort_by { |s| s[:ip] }.should eq expected
    end

    it "registers a service" do
      service = "carrots"
      ip = "127.0.0.1"
      port = 4242
      path = "/etcd/register?ip=#{ip}&port=#{port}&service=#{service}"
      socket = HTTP::WebSocket.new("localhost", path, 6000)
      spawn { socket.run }
      sleep 1

      # check that service registered
      response = curl("GET", "/etcd/services/#{service}")
      body = JSON.parse(response.body)
      services = body.as_a.map { |v| {ip: v["ip"].as_s, port: v["port"].as_i} }
      expected = [{ip: ip, port: port}]

      # close socket, as we have response
      socket.close
      services.sort_by { |s| s[:ip] }.should eq expected
    end

    it "monitors a service" do
      service = "potato"
      path = "/etcd/monitor?monitor=#{service}"

      channel = Channel(String).new
      spawn do
        socket = HTTP::WebSocket.new("localhost", path, 6000)
        socket.on_message do |message|
          channel.send message
          socket.close
        end
        socket.run
      end

      # set a key under the monitored namespace
      ip, port = "0.0.0.0", 42
      client.put("service/#{service}/#{ip}", "#{ip}:#{port}")

      # asynchronously receive event
      message = JSON.parse(channel.receive)
      services = message["body"]["services"].as_a.map { |v| {ip: v["ip"].as_s, port: v["port"].as_i} }

      expected = [{ip: ip, port: port}]
      services.should eq expected
    end

    it "sends custom events" do
      service = "masala"
      path = "/etcd/monitor?monitor=#{service}"

      channel = Channel(String).new
      spawn do
        socket = HTTP::WebSocket.new("127.0.0.1", path, 6000)
        socket.on_message do |message|
          channel.send message
          socket.close
        end
        socket.run
      end

      # define custom event
      event_type = "paddling"
      event_body = "THWACK!"
      message = {
        :event_type => event_type,
        :event_body => event_body,
        :services   => [service],
      }.to_json
      curl("POST", "/etcd/event", body: message)

      message = channel.receive
      result = JSON.parse(message)["body"]

      expected = {
        :event_type => event_type,
        :event_body => event_body,
      }.to_json
      result.should eq expected
    end
  end
end
