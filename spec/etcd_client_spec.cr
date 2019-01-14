require "./spec_helper"
require "json"

describe EtcdClient do
    etcd_host = ENV["ACA_ETCD_HOST"]? || "127.0.0.1"
    etcd_port = (ENV["ACA_ETCD_PORT"]? || 2379).to_i
    etcd_ttl = (ENV["ACA_ETCD_TTL"]? || 60).to_i
    client = EtcdClient.new(etcd_host, etcd_port, etcd_ttl)

    # ==============
    #  Unit Testing
    # ==============
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
