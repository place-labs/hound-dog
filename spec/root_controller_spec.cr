require "./helper"

describe RootController do
  with_server do
    it "responds to liveness probe" do
      response = curl("GET", "/healthz")
      response.success?.should be_true
    end

    it "responds with application version" do
      response = curl("GET", "/version")
      body = JSON.parse(response.body)
      version = body["version"].as_s
      app = body["app"].as_s

      response.success?.should be_true
      version.should eq VERSION
      app.should eq APP_NAME
    end
  end
end
