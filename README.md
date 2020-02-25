# hound-dog

[![Build Status](https://travis-ci.org/aca-labs/hound-dog.svg?branch=master)](https://travis-ci.org/aca-labs/hound-dog)

Library for self-registration and service discovery that utilises Etcd for distributed key-value storage.
Wraps service data in etcd within a [rendezvous hash](https://github.com/caspiano/rendezvous-hash)

## Usage

```crystal
require "hound-dog"

HoundDog.configure do |settings|
  settings.service_namespace = "service"  # namespace for services
  settings.etcd_host = "127.0.0.1"        # etcd connection config
  settings.etcd_port = 2379
  settings.etcd_ttl  = 30                 # TTL for leases
end

# Create a new Discovery instance
discovery = HoundDog::Discovery.new(
  service: "api",
  uri: "https://api1:3000",
)

# There are already some nodes in etcd
discovery.nodes          #=> [{name: "ulid1", uri: #<URI:0xdeadbeef @fragment=nil, @host="api0", @password=nil, @path="", @port=3000, @query=nil, @scheme="https", @user=nil>}]
discovery.find("sauce")  #=> {name: "ulid1", uri: #<URI:0xdeadbeef @fragment=nil, @host="api0", @password=nil, @path="", @port=3000, @query=nil, @scheme="https", @user=nil>}

# Register self to etcd
spawn(same_thread: true) { discovery.register }

# Rendezvous hash transparently updated
discovery.nodes  # [{name: "ulid1", uri: #<URI:0xdeadbeef @fragment=nil, @host="api0", @password=nil, @path="", @port=3000, @query=nil, @scheme="https", @user=nil>}, {name: "ulid2", uri: #<URI:0xbeefcafe @fragment=nil, @host="api0", @password=nil, @path="", @port=3000, @query=nil, @scheme="https", @user=nil>}]
```

## etcd

### Namespacing

All services are registered beneath configured service namespace, i.e. a node under namespace `service` will be keyed as `service/#{service_name}/#{name}`.
Values are base64 encoded strings in the form `uri`.

### Version

Developed against `ETCD_API=3` and etcd-server `v3.3.13`, using etcd's JSON-gRPC API gateway.

## Testing

`$ crystal spec`

## Contributing

1. [Fork it](https://github.com/aca-labs/hound-dog/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Caspian Baska](https://github.com/caspiano) - creator and maintainer
