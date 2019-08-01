require "./helper"

module HoundDog
  describe Discovery do
    it "connects to hound dog server" do
      d = Discovery.new(
        service: "test",
        ip: "1.1.1.1",
        port: 8888,
      )

      d.should_not be_nil
    end

    it "initialises rendezvous hash" do
    end

    it "transparently handles service registration" do
    end

    it "transparently handles service removal" do
    end
  end
end
