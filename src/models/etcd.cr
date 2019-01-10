require "http"
require "json"
require "base64"
require "time"

require "awesome-logger"

##
# Class to communicate with an etcd instance over HTTP
class EtcdClient
    VERSION_PREFIX = "/v3"
    getter :host, :port

    # Creates a new Etcd HTTP client
    # @opts [String] :host IP address of the etcd server (default 127.0.0.1)
    # @opts [Int16]  :port Port number of the etcd server (default 4001)
    # @opts [Int64]  :read_timeout set HTTP read timeouts (default 60)
    def initialize(host : String, port = 4001, ttl = 60)
        @host = host
        @port = port
        @ttl = ttl
    end

    # Returns the etcd daemon version
    def version
        make_http_request("/version", "GET").body
    end

    # Query status of etcd instance
    def status
        api_execute("/maintenance/status", "GET").body
    end

    # Get the current leader
    def leader
        status()[:leader].strip()
    end

    # key 	          key is the key, in bytes, to put into the key-value store. 	                                                    bytes
    # value 	      value is the value, in bytes, to associate with the key in the key-value store. 	                                bytes
    # lease           lease is the lease ID to associate with the key in the key-value store. A lease value of 0 indicates no lease. 	Int64
    # opts
    #   prev_kv 	    If prev_kv is set, etcd gets the previous key-value pair before changing it.
    #                   The previous key-value pair will be returned in the put response. 	                                                Bool
    #   ignore_value 	If ignore_value is set, etcd updates the key using its current value. Returns an error if the key does not exist. 	Bool
    #   ignore_lease 	If ignore_lease is set, etcd updates the key using its current lease. Returns an error if the key does not exist.   Bool
    def put(key, value, lease = 0, options = {} of Symbol => Bool)
        body = {} of Symbol => String
        body[:key] = Base64.encode(key)
        body[:value] = Base64.encode(value)
        body[:lease] = lease
        [:prev_kv, :ignore_value, :ignore_lease].each do |key|
            body[key] = opts[key] if opts[key]?
        end
        api_execute("kv/put", "POST", options) 
    end

    # Convert relative time to absolute time
    def from_relative(relative)
        Time.now.add_span(relative, 0)
    end

    # def delete(key, range_end, ttl)
        # absolute_timeout = from_relative(ttl)

    # Method to request a lease
    # ttl   ttl of granted lease
    # id    id of 0 prompts etcd to assign any id to lease
    def lease_grant(ttl : Int64, id = 0)
        api_execute("lease/grant", "POST", { :TTL => ttl, :ID => 0 })
    end

    # Method to revoke a lease
    # id    id of lease
    def lease_revoke(id : Int64)
        api_execute("lease/revoke", "POST", { :ID => id })
    end

    # Method to query the TTL of a lease
    # id            id of lease
    # query_keys    query all the lease's keys for ttl
    def lease_TTL(id : Int64, query_keys = false)
        api_execute("lease/timetolive", "POST", { :ID => id, :keys => query_keys })
    end

    # Method to request persistence of lease.
    # Must be invoked periodically to avoid key loss
    def lease_keep_alive(id : Int64)
        api_execute("lease/keepalive", "POST", { :ID => id })
    end

    # Method to query all existing leases
    def leases
        api_execute("leases/leases", "POST")
    end

    # def range()
    # end

    # def watch()
    # end

    # Method to send HTTP api requests to etcd server.
    #
    # * path    - etcd server path (etcd server end point)
    # * method  - the request method used
    # * body    - additional parameters used by request method (optional)
    def api_execute(path, method, body = nil)
        raise "Unknown HTTP action: #{method}" unless ["GET", "POST", "PUT", "DELETE"].includes?(method)
        url = VERSION_PREFIX + path
        make_http_request(method, url, body)
    end

    def make_http_request(path, method, body = nil)
        body = URI.encode_www_form(body) unless body.nil?

        HTTP::Client.new(@host, @port) do |http|
            puts @host, @port
            Logger.debug("Invoking: '#{method}' against '#{path}")
            http.connect_timeout = @ttl
            res = http.exec(method, path)
            puts res.to_s
            Logger.debug("Response code: #{res.status_code}")
            Logger.debug("Response body: #{res.body}")
            process_http_response(res)
        end
    end

    def process_http_response(res)
        # Potential for redirection, in such case, original request required
        case res.status_code
        when 200
            Logger.debug("HTTP success")
            res
        when 500
            raise "Etcd Error: {res.body}"
        else
            Logger.debug("HTTP error")
            Logger.debug(res.body)
            raise "HTTP Error: {res.body}"
        end
    end
end