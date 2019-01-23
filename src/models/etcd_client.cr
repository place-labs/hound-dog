require "base64"
require "http"
require "json"
require "logger"
require "time"
require "tokenizer"
require "uri"

# Types for watch event filters
enum WatchFilter
  NOPUT    # filter put events
  NODELETE # filter delete events
end

# Class that communicates with an etcd instance over a HTTP-gRPC gateway
class EtcdClient
  VERSION_PREFIX = "/v3beta"

  getter :host, :port, :logger

  # Creates a new Etcd HTTP client
  # host IP address of the etcd server (default 127.0.0.1)
  # port Port number of the etcd server (default 4001)
  # TTL of leases (default 60)
  def initialize(@host = "127.0.0.1", @port = 4001, @ttl : Int64 = 60)
    @logger = Logger.new(STDOUT)
  end

  # Returns the etcd daemon version
  def version
    make_http_request("GET", "/version").body
  end

  # Queries status of etcd instance
  def status
    response_body = api_execute("POST", "/maintenance/status").body
    status = EtcdStatus.from_json(response_body)
    {
      leader:    status.leader,
      member_id: status.header.try(&.member_id),
      version:   status.version,
    }
  end

  # Queries for current leader of the etcd cluster
  def leader
    status[:leader]
  end

  # Requests a lease
  # ttl   ttl of granted lease                            Int64
  # id    id of 0 prompts etcd to assign any id to lease  UInt64
  def lease_grant(ttl : Int64 = @ttl, id = 0)
    response = api_execute("POST", "/lease/grant", {:TTL => ttl, :ID => 0})

    body = JSON.parse(response.body)
    {
      id:  body["ID"].to_s.to_i64,
      ttl: body["TTL"].to_s.to_i64,
    }
  end

  # Requests persistence of lease.
  # Must be invoked periodically to avoid key loss.
  def lease_keep_alive(id : Int64)
    response = api_execute("POST", "/lease/keepalive", {:ID => id})
    body = JSON.parse(response.body)

    body["result"]["TTL"].to_s.to_i64
  end

  # Queries the TTL of a lease
  # id            id of lease                         Int64
  # query_keys    query all the lease's keys for ttl  Bool
  def lease_ttl(id : Int64, query_keys = false)
    response = api_execute("POST", "/kv/lease/timetolive", {:ID => id, :keys => query_keys})
    body = JSON.parse(response.body)

    {
      granted_ttl: body["grantedTTL"].to_s.to_i64,
      ttl:         body["TTL"].to_s.to_i64,
    }
  end

  # Revokes an etcd lease
  # id  Id of lease  Int64
  def lease_revoke(id : Int64)
    response = api_execute("POST", "/kv/lease/revoke", {:ID => id})

    response.success?
  end

  # Queries for all existing leases in an etcd cluster
  def leases
    response_body = api_execute("POST", "/kv/lease/leases").body
    body = JSON.parse(response_body)

    body["leases"].as_a.map { |l| l["ID"].as_s.to_i64 }
  end

  # Sets a key and value in etcd.
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

  # Deletes key or range of keys
  def delete(key, range_end = "")
    post_body = {
      :key       => Base64.strict_encode(key),
      :range_end => Base64.strict_encode(range_end),
    }
    response = api_execute("POST", "/kv/deleterange", post_body)
    if response.success?
      body = JSON.parse(response.body)
      body["deleted"]?.try(&.to_s.to_i64) || 0
    else
      nil
    end
  end

  # Deletes an entire keyspace prefix
  def delete_prefix(prefix)
    delete(prefix, prefix_range_end prefix)
  end

  # Calculate range_end for given prefix
  def prefix_range_end(prefix)
    prefix.size > 0 ? prefix.sub(-1, prefix[-1] + 1) : ""
  end

  # Queries a range of keys
  def range(key, range_end = "")
    parameters = {
      :key       => Base64.strict_encode(key),
      :range_end => Base64.strict_encode(range_end),
    }
    response = api_execute("POST", "/kv/range", parameters)
    body = JSON.parse(response.body)
    kvs = body["kvs"]?.try(&.as_a) || [] of JSON::Any
    kvs.map do |h|
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

  # Watches an etcd key/range, passing events to a supplied block.
  # key              key is the key to register for watching.                                                                                String
  # opts
  #  range_end       range_end is the end of the range [key, range_end) to watch.
  #  filters         filters filter the events at server side before it sends back to the watcher.                                           [WatchFilter]
  #  start_revision  start_revision is an optional revision to watch from (inclusive). No start_revision is "now".                           Int64
  #  progress_notify progress_notify is set so that the etcd server will periodically send a WatchResponse with no events to the new watcher
  #                  if there are no recent events. It is useful when clients wish to recover a disconnected watcher starting from
  #                  a recent known revision. The etcd server may decide how often it will send notifications based on current load.         Bool
  #  prev_kv         If prev_kv is set, created watcher gets the previous KV before the event happens.                                       Bool
  def watch(key, **opts, &block : Array(EtcdWatchEvent) -> Void)
    opts = {
      key: key,
    }.merge(opts)

    options = {} of Symbol => String | Int64 | Bool | Array(WatchFilter)
    {:key, :range_end, :prev_kv, :progress_notify, :start_revision, :filters}.each do |k|
      options[k] = opts[k] if opts.has_key?(k)
    end

    # Base64 key and range_end
    {:key, :range_end}.each do |k|
      option = options[k]?
      options[k] = Base64.strict_encode(option) if option && option.is_a?(String)
    end

    post_body = {:create_request => options}
    begin
      HTTP::Client.post("#{host}:#{port}#{VERSION_PREFIX}/watch", body: post_body.to_json) do |stream|
        consume_io(stream.body_io, json_chunk_tokenizer) do |chunk|
          response = EtcdWatchResponse.from_json(chunk)
          raise IO::EOFError.new if response.error

          # Unmarshall Base64 encoded key and value
          events = response.try(&.result.try(&.events)) || [] of EtcdWatchEvent
          events = events.map do |event|
            event.kv = event.try(&.kv).try do |kv|
              kv.key = kv.try(&.key).try { |k| Base64.decode_string k }
              kv.value = kv.try(&.value).try { |v| Base64.decode_string v }
              kv
            end
            event
          end

          # Ignore "created" message
          block.call events unless response.created
        end
      end
    rescue error
      logger.error "in watch\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
    end
  end

  # Watches keys by prefix
  def watch_prefix(prefix, **opts, &block : Array(EtcdWatchEvent) -> Void)
    opts = opts.merge({range_end: prefix_range_end prefix})
    watch(prefix, **opts, &block)
  end

  # Partitions IO into JSON chunks (only objects!)
  def json_chunk_tokenizer
    Tokenizer.new do |io|
      length, unpaired = 0, 0
      loop do
        char = io.read_char
        break unless char
        unpaired += 1 if char == '{'
        unpaired -= 1 if char == '}'
        length += 1
        break if unpaired == 0
      end
      unpaired == 0 && length > 0 ? length : -1
    end
  end

  # Pulls tokens off stream IO, and calls block with tokenized IO
  # io          Streaming IO                                      IO
  # tokenizer   Tokenizer class with which the stream is parsed   Tokenizer
  # block       Block that takes a string                         Block
  def consume_io(io, tokenizer, &block : String -> Void)
    raw_data = Bytes.new(4096)
    while !io.closed?
      bytes_read = io.read(raw_data)
      break if bytes_read == 0 # IO was closed
      tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        spawn { block.call String.new(message) }
      end
    end
  end

  # Converts literals to string type
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

  # Sends HTTP api requests to etcd server.
  # method  the request method used                                   String
  # path    etcd server path (etcd server end point)                  String
  # body    additional parameters used by request method (optional)   Nil | Hash
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
      logger.debug("Invoking: '#{method}' against '#{path}'")
      response = http.exec(method, path, body: body)
      logger.debug("Response: #{response.status_code} #{response.body}")
      process_http_response(response)
    end
  end

  def process_http_response(response)
    # In the case of redirection, original request required.
    case response.status_code
    when 200
      logger.debug("HTTP success")
      response
    when 500
      raise "Etcd Error: #{response.body}"
    else
      logger.debug("HTTP error")
      logger.debug(response.body)
      raise "HTTP Error: #{response.body}"
    end
  end
end

# Converter for stringly typed values, such as etcd response values
module StringTypedJSONConverter(T)
  def self.from_json(value : JSON::PullParser) : T
    T.new(value.read_string)
  end
end

# Models of Etcd responses.
# Refer to documentation https://coreos.com/etcd/docs/latest/dev-guide/api_reference_v3.html
############################################################################################

class EtcdResponseHeader < ActiveModel::Model
  attribute cluster_id : UInt64, converter: StringTypedJSONConverter(UInt64)
  attribute member_id : UInt64, converter: StringTypedJSONConverter(UInt64)
  attribute revision : Int64, converter: StringTypedJSONConverter(Int64)
  attribute raft_term : UInt64, converter: StringTypedJSONConverter(UInt64)
end

class EtcdWatchResponse < ActiveModel::Model
  attribute result : EtcdWatchResult
  attribute error : EtcdWatchError
  attribute created : Bool = false
end

class EtcdWatchError < ActiveModel::Model
  attribute http_code : Int32
end

class EtcdWatchResult < ActiveModel::Model
  attribute events : Array(EtcdWatchEvent) = [] of EtcdWatchEvent
end

class EtcdWatchKV < ActiveModel::Model
  include ActiveModel::Validation
  attribute key : String
  attribute value : String
  validates :key, if: Proc.new(EtcdWatchKV) do |kv|
    key = kv["key"]?
    key != nil
  end
end

class EtcdWatchEvent < ActiveModel::Model
  include ActiveModel::Validation
  attribute type : String
  attribute kv : EtcdWatchKV
  validates :kv, presence: true
  validates :kv, if: Proc.new(EtcdWatchEvent) do |event|
    kv = event["kv"]?
    kv != nil
  end
end

class EtcdStatus < ActiveModel::Model
  attribute header : EtcdResponseHeader
  attribute version : String
  attribute dbSize : Int64, converter: StringTypedJSONConverter(Int64) # ameba:disable Style/VariableNames
  attribute leader : UInt64, converter: StringTypedJSONConverter(UInt64)
  attribute raftIndex : UInt64, converter: StringTypedJSONConverter(UInt64) # ameba:disable Style/VariableNames
  attribute raftTerm : UInt64, converter: StringTypedJSONConverter(UInt64)  # ameba:disable Style/VariableNames
end
