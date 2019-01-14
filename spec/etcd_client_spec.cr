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
            lease_ttl = client.lease_TTL lease[:id]
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
    end
end
