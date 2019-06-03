# Hound Dog

Service sidecar for self-registration and service discovery that utilises Etcd for distributed key-value storage.

## Etcd

### Namespacing

All services are registered beneath the "service/" namespace e.g. "service/engine/192.168.10.3"

### Version

Developed against etcd-server `v3.3.13`, and `ETCD_API=3`

## API

### WS ../etcd/register

Websocket endpoint to register service node in etcd until termination of socket connection.
Events for the service under which the node is namespaced are pushed to the client.  
Optionally, the monitor field allows subscription to all events under requested service namespaces.

#### Request

| Param   | Description                                         | Type          |
|--------:|:----------------------------------------------------|:--------------|
| service | Service name to register                            | String        |
| ip      | Ip of registered service                            | String        |
| port    | Service port of registered service                  | Int16         |
| monitor | Comma seperated service names to monitor (Optional) | Array(String) |

#### Response

Websocket emits Message

### WS ../etcd/monitor

Websocket endpoint to register for all events for desired service namespaces.

#### Request

| Param   | Description                              | Type          |
|--------:|:-----------------------------------------|:--------------|
| monitor | comma seperated service names to monitor | Array(String) |

#### Response

Websocket emits Message

### POST ../etcd/event

Emit a custom event to some/all namespaces

#### Request

| Param      | Description                                      | Type          |
|-----------:|:-------------------------------------------------|:--------------|
| event_type | type of event                                    | String        |
| event_body | stringified event                                | String        |
| broadcast  | (optional) port of service                       | Int16         |
| services   | (optional) receive events of additional services | Array(String) |

#### Response

`200 OK` || `400 Bad Request` || `500 Internal Server Error`

### GET ../etcd/leader

Returns the member_id the current etcd node instance believes corresponds to the cluster leader and id of connected etcd instance.
Useful for performing leader election.

#### Response

| Value      | Description                              | Type          |
|-----------:|:-----------------------------------------|:--------------|
| leader     | Id of the believed cluster leader        | UInt64        |
| member_id  | Id of connected etcd instance            | UInt64        |

### GET ../etcd/services

Lists service namespaces present in the key-value store

#### Response

| Value     | Description                              | Type          |
|----------:|:-----------------------------------------|:--------------|
| services  | active service namespaces                | Array(String) |

### GET ../etcd/services/:service

Lists service nodes beneath the specified namespace.

#### Response

| Value     | Description                               | Type           |
|----------:|:------------------------------------------|:---------------|
| services  | array of current services under namespace | Array(Service) |

## Types

### MessageType

Received by listening websocket when event occurs under a subscribed namespace specified in a register/monitor request

| Value      | Description                             | Type                      |
|-----------:|:----------------------------------------|:--------------------------|
| namespace  | active service namespaces               | String                    |
| body       | namespace specific JSON body            | ServiceBody \| CustomBody |

### ServiceBody

Received by listener subscribed to service namespace

| Value       | Description                               | Type                      |
|------------:|:------------------------------------------|:--------------------------|
| key_event   | one of `PUT`, `DELETE`, `EXPIRE`          | String                    |
| services    | array of current services under namespace | Array(Service)            |

### CustomBody

Received by listener subscribed to service namespaces specified in event request.  
Fields event_body and event_type as set in `/etcd/event` request.

| Value            | Description            | Type          |
|-----------------:|:-----------------------|:--------------|
| event_type       | type of event          | String        |
| event_body       | stringified event      | String        |

### Service

| Value    | Description                             | Type     |
|---------:|:----------------------------------------|:---------|
| ip       | Ip of registered service                | String   |
| port     | Service port of registered service      | Int16    |

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
