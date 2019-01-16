# Hound Dog

Service sidecar for self-registration and service discovery that utilises Etcd for distributed key-value storage.

# API

## /etcd

### ../register

Websocket endpoint to register service node in etcd until termination of socket connection.
Events for the service under which the node is namespaced are pushed to the client.  
Optionally, the monitor field allows subscription to all events under requested service namespaces.

|Param    | Description                                         | Type          |
|--------:|:----------------------------------------------------|:--------------|
| service | Service name to register                            | String        |
| ip      | Ip of registered service                            | String        |
| port    | Service port of registered service                  | Int16         |
| monitor | Comma seperated service names to monitor (Optional) | Array(String) |



### ../monitor

Websocket endpoint to register for all events for desired service namespaces.

|Param    | Description                              | Type          |
|--------:|:-----------------------------------------|:--------------|
| monitor | comma seperated service names to monitor | Array(String) |


### ../leader

Returns the who the current etcd node instance believes is the cluster leader.


**Response**
```json
{
  "leader": "instanceid"
}
```


## Etcd Namespacing

All services are registered beneath the "service/" namespace e.g. "service/engine/server/192.168.10.3"


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
