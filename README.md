# hound-dog

[![Build Status](https://travis-ci.org/aca-labs/hound-dog.svg?branch=master)](https://travis-ci.org/aca-labs/hound-dog)

Library for self-registration and service discovery that utilises Etcd for distributed key-value storage.

Wraps service data in etcd within a [rendezvous hash](https://github.com/caspiano/rendezvous-hash)

## Usage

```crystal

# Create a new Discovery instance
discovery = Discovery.new(
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

All services are registered beneath the `service` namespace e.g. `service/engine/192.168.10.3`

Keys are in the form `"#{ip}:#{port}"` then base64 encoded

### Version

Developed against etcd-server `v3.3.13`, and `ETCD_API=3`

## Testing

`crystal spec`

## Contributing

1. [Fork it](https://github.com/aca-labs/hound-dog/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Caspian Baska](https://github.com/caspiano) - creator and maintainer
