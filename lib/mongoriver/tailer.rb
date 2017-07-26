module Mongoriver
  class Tailer
    include Mongoriver::Logging
    include Mongoriver::Assertions

    attr_reader :upstream_conn
    attr_reader :oplog

    def initialize(upstreams, type, oplog = "oplog.rs")
      @upstreams = upstreams
      @type = type
      @oplog = oplog
      # This number seems high
      @conn_opts = {:op_timeout => 86400}

      @cursor = nil
      @stop = false
      @streaming = false

      connect_upstream
    end

    # Return a position for a record object
    #
    # @return [BSON::Timestamp] if mongo
    # @return [BSON::Binary] if tokumx
    def position(record)
      return nil unless record
      record['ts']
    end

    # Return a time for a record object
    # @return Time
    def time_for(record)
      return nil unless record
      Time.at(record['ts'].seconds)
    end

    # Find the most recent entry in oplog and return a position for that
    # position. The position can be passed to the tail function (or run_forever)
    # and the tailer will start tailing after that.
    # If before_time is given, it will return the latest position before (or at) time.
    def most_recent_position(before_time=nil)
      position(latest_oplog_entry(before_time))
    end

    def latest_oplog_entry(before_time=nil)
      query = {}
      if before_time
        ts = BSON::Timestamp.new(before_time.to_i + 1, 0)
        query = { 'ts' => { '$lt' => ts } }
      end

      record = oplog_collection.find_one(query, :sort => [['$natural', -1]])
      record
    end

    def connect_upstream
      case @type
      when :replset
        opts = @conn_opts.merge(:read => :secondary)
        @upstream_conn = Mongo::ReplSetConnection.new(@upstreams, opts)
      when :slave, :direct
        opts = @conn_opts.merge(:slave_ok => true)
        host, port = parse_direct_upstream
        @upstream_conn = Mongo::Connection.new(host, port, opts)
        raise "Server at #{@upstream_conn.host}:#{@upstream_conn.port} is the primary -- if you're ok with that, check why your wrapper is passing :direct rather than :slave" if @type == :slave && @upstream_conn.primary?
        ensure_upstream_replset!
      when :existing
        raise "Must pass in a single existing Mongo::Connection with :existing" unless @upstreams.length == 1 && @upstreams[0].respond_to?(:db)
        @upstream_conn = @upstreams[0]
      else
        raise "Invalid connection type: #{@type.inspect}"
      end
    end

    def connection_config
      @upstream_conn['admin'].command(:ismaster => 1)
    end

    def ensure_upstream_replset!
      # Might be a better way to do this, but not seeing one.
      config = connection_config
      unless config['setName']
        raise "Server at #{@upstream_conn.host}:#{@upstream_conn.port} is not running as a replica set"
      end
    end

    def parse_direct_upstream
      raise "When connecting directly to a mongo instance, must provide a single upstream" unless @upstreams.length == 1
      upstream = @upstreams[0]
      parse_host_spec(upstream)
    end

    def parse_host_spec(host_spec)
      host, port = host_spec.split(':')
      host = '127.0.0.1' if host.to_s.length == 0
      port = '27017' if port.to_s.length == 0
      [host, port.to_i]
    end

    def oplog_collection
      @upstream_conn.db('local').collection(oplog)
    end

    # Start tailing the oplog.
    # 
    # @param [Hash]
    # @option opts [BSON::Timestamp, BSON::Binary] :from Placeholder indicating 
    #           where to start the query from. Binary value is used for tokumx.
    #           The timestamp is non-inclusive.
    # @option opts [Hash] :filter Extra filters for the query.
    # @option opts [Bool] :dont_wait(false) 
    def tail(opts = {})
      raise "Already tailing the oplog!" if @cursor

      query = build_tail_query(opts)

      mongo_opts = {:timeout => false}.merge(opts[:mongo_opts] || {})

      oplog_collection.find(query, mongo_opts) do |oplog|
        oplog.add_option(Mongo::Constants::OP_QUERY_TAILABLE)
        oplog.add_option(Mongo::Constants::OP_QUERY_OPLOG_REPLAY) if query['ts']
        oplog.add_option(Mongo::Constants::OP_QUERY_AWAIT_DATA) unless opts[:dont_wait]

        log.debug("Starting oplog stream from #{opts[:from] || 'start'}")
        @cursor = oplog
      end
    end

    # Deprecated: use #tail(:from => ts, ...) instead
    def tail_from(ts, opts={})
      opts.merge(:from => ts)
      tail(opts)
    end

    def tailing
      !@stop || @streaming
    end

    def stream(limit=nil, &blk)
      count = 0
      @streaming = true
      while !@stop && @cursor.has_next?
        count += 1
        break if limit && count >= limit

        record = @cursor.next
        blk.call(record)
      end
      @streaming = false

      @cursor.has_next?
    end

    def stop
      @stop = true
    end

    def close
      @cursor.close if @cursor
      @cursor = nil
      @stop = false
    end

    private
    def build_tail_query(opts = {})
      query = opts[:filter] || {}
      return query unless opts[:from]
      assert(opts[:from].is_a?(BSON::Timestamp),
        "For mongo databases, tail :from must be a BSON::Timestamp")
      query['ts'] = { '$gt' => opts[:from] }
      query['ns'] = "#{opts[:db]}.#{opts[:collection]}" if opts[:collection]

      query
    end
  end
end
