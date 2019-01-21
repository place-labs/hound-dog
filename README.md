# Hound Dog

Service sidecar for self-registration and service discovery that utilises Etcd for distributed key-value storage.

## Etcd Namespacing

All services are registered beneath the "service/" namespace e.g. "service/engine/server/192.168.10.3"

# API

## /etcd

### WS ../register

Websocket endpoint to register service node in etcd until termination of socket connection.
Events for the service under which the node is namespaced are pushed to the client.  
Optionally, the monitor field allows subscription to all events under requested service namespaces.

|Param    | Description                                         | Type          |
|--------:|:----------------------------------------------------|:--------------|
| service | Service name to register                            | String        |
| ip      | Ip of registered service                            | String        |
| port    | Service port of registered service                  | Int16         |
| monitor | Comma seperated service names to monitor (Optional) | Array(String) |

### WS ../monitor

Websocket endpoint to register for all events for desired service namespaces.

|Param    | Description                              | Type          |
|--------:|:-----------------------------------------|:--------------|
| monitor | comma seperated service names to monitor | Array(String) |

### GET ../leader

Returns the node id that the current etcd node instance believes corresponds to the cluster leader.

#### Response

| Value   | Description                              | Type          |
|--------:|:-----------------------------------------|:--------------|
| leader  | Id of the believed cluster leader        | UInt64        |

### GET ../services

Lists service namespaces present in the key-value store

#### Response

| Value     | Description                              | Type          |
|----------:|:-----------------------------------------|:--------------|
| services  | active service namespaces                | Array(String) |

### GET ../services/:service

Lists service nodes beneath the specified namespace.

#### Response

| Value     | Description                               | Type          |
|----------:|:------------------------------------------|:--------------|
| services  | keys for nodes beneath service namespaces | Array(String) |

-----------------------------------------------------------------------------------------------------------  

# Spider-Gazelle Application Template

[![Build Status](https://travis-ci.org/spider-gazelle/spider-gazelle.svg?branch=master)](https://travis-ci.org/spider-gazelle/spider-gazelle)

Clone this repository to start building your own spider-gazelle based application

## Documentation

Detailed documentation and guides available: https://spider-gazelle.net/

* [Action Controller](https://github.com/spider-gazelle/action-controller) base class for building [Controllers](http://guides.rubyonrails.org/action_controller_overview.html)
* [Active Model](https://github.com/spider-gazelle/active-model) base class for building [ORMs](https://en.wikipedia.org/wiki/Object-relational_mapping)
* [Habitat](https://github.com/luckyframework/habitat) configuration and settings for Crystal projects
* [router.cr](https://github.com/tbrand/router.cr) base request handling
* [Radix](https://github.com/luislavena/radix) Radix Tree implementation for request routing
* [HTTP::Server](https://crystal-lang.org/api/latest/HTTP/Server.html) built-in Crystal Lang HTTP server
  * Request
  * Response
  * Cookies
  * Headers
  * Params etc


Spider-Gazelle builds on the amazing performance of **router.cr** [here](https://github.com/tbrand/which_is_the_fastest).:rocket:


## Testing

`crystal spec`

* to run in development mode `crystal ./src/app.cr`

## Compiling

`crystal build ./src/app.cr`

### Deploying

Once compiled you are left with a binary `./app`

* for help `./app --help`
* viewing routes `./app --routes`
* run on a different port or host `./app -b 0.0.0.0 -p 80`
