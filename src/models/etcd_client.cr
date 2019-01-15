require "awesome-logger"
require "base64"
require "http"
require "json"
require "time"
require "uri"

# Converter for stringly typed values, such as etcd response values
module StringTypedJSONConverter(T)
  def self.from_json(value : JSON::PullParser) : T
    T.new(value.read_string)
  end
end

class EtcdResponseHeader < ActiveModel::Model
  attribute cluster_id : UInt64, converter: StringTypedJSONConverter(UInt64)
  attribute member_id : UInt64, converter: StringTypedJSONConverter(UInt64)
  attribute revision : Int64, converter: StringTypedJSONConverter(Int64)
  attribute raft_term : UInt64, converter: StringTypedJSONConverter(UInt64)
end

class EtcdStatus < ActiveModel::Model
  attribute header : EtcdResponseHeader
  # version is the cluster protocol version used by the responding member.
  attribute version : String
  # dbSize is the size of the backend database, in bytes, of the responding member.
  attribute dbSize : Int64, converter: StringTypedJSONConverter(Int64)
  # leader is the member ID which the responding member believes is the current leader.
  attribute leader : UInt64, converter: StringTypedJSONConverter(UInt64)
  # raftIndex is the current raft index of the responding member.
  attribute raftIndex : UInt64, converter: StringTypedJSONConverter(UInt64)
  # raftTerm is the current raft term of the responding member.
  attribute raftTerm : UInt64, converter: StringTypedJSONConverter(UInt64)
end

##
# Class to communicate with an etcd instance over HTTP
class EtcdClient
  VERSION_PREFIX = "/v3beta"

  enum WatchFilter
    NOPUT
    NODELETE
  end

  getter :host, :port

  # Creates a new Etcd HTTP client
  # host IP address of the etcd server (default 127.0.0.1)
  # port Port number of the etcd server (default 4001)
  # TTL of leases (default 60)
  def initialize(host = "127.0.0.1", port = 4001, ttl : Int64 = 60)
    @host = host
    @port = port
    @ttl = ttl
  end

  # Returns the etcd daemon version
  def version
    make_http_request("GET", "/version").body
  end

  # Query status of etcd instance
  def status
    response_body = api_execute("POST", "/maintenance/status").body
    EtcdStatus.from_json(response_body)
  end

  # Get the current leader
  def leader
    status.leader
  end

  # Method to request a lease
  # ttl   ttl of granted lease
  # id    id of 0 prompts etcd to assign any id to lease
  def lease_grant(ttl : Int64 = @ttl, id = 0)
    response = api_execute("POST", "/lease/grant", {:TTL => ttl, :ID => 0})
    body = JSON.parse(response.body)

    {
      id:  body["ID"].to_s.to_i64,
      ttl: body["TTL"].to_s.to_i64,
    }
  end

  # Method to request persistence of lease.
  # Must be invoked periodically to avoid key loss
  def lease_keep_alive(id : Int64)
    response = api_execute("POST", "/lease/keepalive", {:ID => id})
    body = JSON.parse(response.body)

    body["result"]["TTL"].to_s.to_i64
  end

  # Method to query the TTL of a lease
  # id            id of lease
  # query_keys    query all the lease's keys for ttl
  def lease_ttl(id : Int64, query_keys = false)
    response = api_execute("POST", "/kv/lease/timetolive", {:ID => id, :keys => query_keys})
    body = JSON.parse(response.body)

    {
      id:  body["grantedTTL"].to_s.to_i64,
      ttl: body["TTL"].to_s.to_i64,
    }
  end

  # Method to revoke a lease
  # id    id of lease
  def lease_revoke(id : Int64)
    response = api_execute("POST", "/kv/lease/revoke", {:ID => id})

    response.success?
  end

  # Method to query all existing leases
  def leases
    response_body = api_execute("POST", "/kv/lease/leases").body
    body = JSON.parse(response_body)

    body["leases"].as_a.map { |l| l["ID"].as_s.to_i64 }
  end

  # key             key is the string that will be base64 encoded and associated with value in the kv store                          String
  # value           value is the string that will be base64 encoded and associated with key in the kv store                          String
  # opts
  #   lease         lease is the lease ID to associate with the key in the key-value store. A lease value of 0 indicates no lease.   Int64
  #   prev_kv       If prev_kv is set, etcd gets the previous key-value pair before changing it.
  #                 The previous key-value pair will be returned in the put response.                                                 Bool
  #   ignore_value  If ignore_value is set, etcd updates the key using its current value. Returns an error if the key does not exist  Bool
  #   ignore_lease  If ignore_lease is set, etcd updates the key using its current lease. Returns an error if the key does not exist  Bool
  def put(key, value, **opts)
    opts = {
      key:   Base64.strict_encode(key),
      value: Base64.strict_encode(value),
      lease: 0_i64,
    }.merge(opts)

    parameters = {} of Symbol => String | Int64 | Bool
    {:key, :value, :lease, :prev_kv, :ignore_value, :ignore_lease}.each do |param|
      parameters[param] = opts[param] if opts.has_key?(param)
    end
    response = api_execute("POST", "/kv/put", parameters)

    if opts["prev_kv"]?
      JSON.parse(response.body)["prev_kv"]
    else
      response.success?
    end
  end

  # Delete key or range of keys
  def delete(key, range_end = "")
    response = api_execute("POST", "/kv/deleterange", {:key => key, :range_end => range_end})
    if response.success?
      body = JSON.parse(response.body)
      body["deleted"].to_s.to_i64
    else
      nil
    end
  end

  # Method to calculate range_end for given prefix
  def prefix_range_end(prefix)
    prefix.sub(-1, prefix[-1] + 1)
  end

  # Method to query a range of keys
  def range(key, range_end = "")
    parameters = {
      :key       => Base64.strict_encode(key),
      :range_end => Base64.strict_encode(range_end),
    }
    response = api_execute("POST", "/kv/range", parameters)
    body = JSON.parse(response.body)

    body["kvs"].as_a.map do |h|
      {
        key:             Base64.decode_string(h["key"].as_s),
        value:           Base64.decode_string(h["value"].as_s),
        create_revision: Base64.decode_string(h["create_revision"].as_s),
      }
    end
  end

  # Method to query keys by prefix
  def range_prefix(prefix)
    range(prefix, prefix_range_end prefix)
  end

  # key              key is the key to register for watching.                                                                                String
  # opts
  #  range_end       range_end is the end of the range [key, range_end) to watch.
  #                  If range_end is not given, only the key argument is watched.
  #                  If range_end is equal to '0', all keys greater than or equal to the key argument are watched.
  #                  If the range_end is one bit larger than the given key, then all keys with the prefix (the given key) will be watched.   String
  #  start_revision  start_revision is an optional revision to watch from (inclusive). No start_revision is "now".                           Int64
  #  progress_notify progress_notify is set so that the etcd server will periodically send a WatchResponse with no events to the new watcher
  #                  if there are no recent events. It is useful when clients wish to recover a disconnected watcher starting from
  #                  a recent known revision. The etcd server may decide how often it will send notifications based on current load.         Bool
  #  filters         filters filter the events at server side before it sends back to the watcher.   `                                       WatchFilter
  #  prev_kv         If prev_kv is set, created watcher gets the previous KV before the event happens.
  #                  If the previous KV is already compacted, nothing will be returned.                                                      Bool
  def watch_create(key, **opts)
    opts = {
      key:       key,
      range_end: "",
    }.merge(opts)

    create_request = {} of Symbol => String | Int64 | Bool | Array(WatchFilter)
    {:key, :range_end, :prev_kv, :progress_notify, :start_revision, :filters}.each do |k|
      create_request[k] = opts[k] if opts.has_key?(k)
    end
    parameters = {
      :create_request => create_request,
      :cancel_request => nil,
    }
    response = api_execute("POST", "/watch", parameters)
    JSON.parse(response.body)
  end

  # Method to watch keys by prefix
  def watch_prefix(prefix, **opts)
    opts = opts.merge({range_end: prefix_range_end prefix})
    watch_create(prefix, **opts)
  end

  def watch_cancel(watch_id)
    parameters = {
      :create_request => nil,
      :cancel_request => {:watch_id => watch_id},
    }
    response = api_execute("POST", "/watch", parameters)

    response.success? && JSON.parse(response.body)["canceled"].as_bool
  end

  # Convert literals to string type
  def to_stringly(value)
    case value
    when Array, Tuple
      value.map { |v| to_stringly v }
    when Hash
      value.transform_values { |v| to_stringly v }
    when NamedTuple
      to_stringly value.to_h
    when Bool
      value
    else
      value.to_s
    end
  end

  # Method to send HTTP api requests to etcd server.
  #
  # path    - etcd server path (etcd server end point)
  # method  - the request method used
  # body    - additional parameters used by request method (optional)
  def api_execute(method, path, body : Nil | Hash = nil)
    raise "Unknown HTTP action: #{method}" unless {"GET", "POST", "PUT", "DELETE"}.includes?(method)
    url = VERSION_PREFIX + path

    # Etcd expects stringly typed fields in request (artifact of gRPC http gateway)
    body = to_stringly body unless body.nil?

    make_http_request(method, url, body)
  end

  def make_http_request(method, path, body = nil)
    body = body.to_json unless body.nil?

    # Client expects JSON POST body
    if method == "POST" && body.nil?
      body = "{}"
    end

    HTTP::Client.new(@host, @port) do |http|
      Logger.debug("Invoking: '#{method}' against '#{path}'")
      response = http.exec(method, path, body: body)
      Logger.debug("Response: #{response.status_code} #{response.body}")
      process_http_response(response)
    end
  end

  def process_http_response(response)
    # In the case of redirection, original request required.
    case response.status_code
    when 200
      Logger.debug("HTTP success")
      response
    when 500
      raise "Etcd Error: #{response.body}"
    else
      Logger.debug("HTTP error")
      Logger.debug(response.body)
      raise "HTTP Error: #{response.body}"
    end
  end
end
