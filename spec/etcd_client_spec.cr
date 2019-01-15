require "./spec_helper"
require "json"

describe EtcdClient do
  etcd_host = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
  etcd_port = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
  etcd_ttl = (ENV["ACA_ETCD_TTL"]? || 5).to_i64
  client = EtcdClient.new(etcd_host, etcd_port, etcd_ttl)

  # ==============
  #  Unit Testing
  # ==============

  describe "Cluster Status" do
    it "queries version" do
      version = JSON.parse(client.version).as_h
      version.has_key?("etcdserver").should be_true
    end

    it "queries status of cluster" do
      status = client.status
      status.should be_a EtcdStatus
    end

    it "queries leader" do
      leader = client.leader
      leader.should be_a UInt64
    end
  end

  describe "Leases" do
    it "requests a lease" do
      lease = client.lease_grant etcd_ttl
      lease[:ttl].should eq etcd_ttl
    end

    it "queries ttl of lease" do
      lease = client.lease_grant etcd_ttl
      lease_ttl = client.lease_ttl lease[:id]
      lease_ttl[:ttl].should be <= etcd_ttl
    end

    it "queries active leases" do
      lease = client.lease_grant etcd_ttl
      active_leases = client.leases
      lease_present = active_leases.any? { |id| id == lease[:id] }
      lease_present.should be_true
    end

    it "revokes a lease" do
      lease = client.lease_grant etcd_ttl
      response = client.lease_revoke lease[:id]
      response.should be_true
    end

    it "extends a lease" do
      lease = client.lease_grant etcd_ttl
      new_ttl = client.lease_keep_alive lease[:id]
      new_ttl.should be > 0
    end
  end

  describe "Key/Value" do
    it "sets a value" do
      response = client.put("hello", "world")
      response.should be_true
    end

    it "queries a range of keys" do

      key, value = "foo", "bar"
      client.put(key, value)
      range = client.range(key)

      present = range.any? { |r| r[:key] == key && r[:value] == value }
      present.should be_true
    end

    it "queries keys by prefix" do
      lease = client.lease_grant etcd_ttl
      key0, value0 = "foo", "bar"
      key1, value1 = "foot", "bath"

      client.put(key0, value0, lease: lease[:id])
      client.put(key1, value1, lease: lease[:id])
      range = client.range_prefix key0

      present = range.any? { |r| r[:key] == key1 && r[:value] == value1 }
      present.should be_true
    end
  end
end