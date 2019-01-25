require "./spec_helper"
require "../src/config"
require "json"

describe RootController do
  with_server do
    it "responds to liveness probe" do
      response = curl("GET", "/ping")
      response.success?.should be_true
    end

    it "responds with application version" do
      response = curl("GET", "/version")
      body = JSON.parse(response.body)
      version = body["version"].as_s

      response.success?.should be_true
      version.should eq VERSION
    end
  end
end
