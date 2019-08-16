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
  ip: "127.0.0.1",
  port: 1996,
)

# There are already some nodes in etcd
discovery.nodes          #=> [{ip: "some ip", port: 8080}]
discovery.find("sauce")  #=> {ip: "some ip", port: 8080}

# Register self to etcd
spawn discovery.register

# Rendezvous hash transparently updated
discovery.nodes          #=> [{ip: "some ip", port: 8080}, {ip: "127.0.0.1", port: 1996}]
```

## etcd

### Namespacing

All services are registered beneath configured service namespace, i.e. a node under namespace `service` will be keyed as `service/#{service_name}/#{service_ip}`.
Values are base64 encoded strings in the form `"#{ip}:#{port}"`.

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
