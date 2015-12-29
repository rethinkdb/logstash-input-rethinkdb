# encoding: utf-8

require "logstash/inputs/base"
require "logstash/namespace"
require "eventmachine"
require "rethinkdb"

class LogStash::Inputs::RethinkDB < LogStash::Inputs::Base
  config_name "rethinkdb"
  default :codec, "json_lines"
  attr_accessor :logger

  include RethinkDB::Shortcuts

  # Hostname of RethinkDB server
  config :host, :validate => :string, :default => "localhost"
  # Driver connection port of RethinkDB server
  config :port, :validate => :number, :default => 28015
  # Auth key of RethinkDB server (don't provide if nil)
  config :auth_key, :validate => :string, :default => ""
  # Time period to squash changefeeds on. Defaults to no squashing.
  config :squash, :default => true
  # Which tables to watch for changes
  config :watch_tables, :validate => :array, :default => []
  # Which databases to watch for changes. Tables added or removed from
  # these databases will be watched or unwatched accordingly
  config :watch_dbs, :validate => :array, :default => []
  # Whether to backfill documents from the dbs and tables when
  # (re)connecting to RethinkDB. This ensures all documents in the
  # RethinkDB tables will be sent over logstash, but it may cause a
  # lot of traffic with very large tables and/or unstable connections.
  config :backfill, :default => true


  # Part of the logstash input interface
  def register
    # {db => {table => QueryHandle}}
    @table_feeds = Hash.new { |hsh, key| hsh[key] = {} }
    # {db => QueryHandle}
    @db_feeds = {}
    @queue = nil
    @backfill = @backfill && @backfill != 'false'
    @squash = @squash && @squash != 'false'
  end

  # # Part of the logstash input interface
  def run(queue)
    @queue = queue
    @conn = r.connect(
      :host => @host,
      :port => @port,
      :auth_key => @auth_key,
    )
    EM.run do
      @logger.log "Eventmachine loop started"
      @watch_dbs.uniq.each do |db|
        create_db_feed(db, DBHandler.new(db, self))
      end
      @watch_tables.uniq.each do |db_table|
        db, table = db_table.split '.'
        db, table = "test", db if table.nil?
        update_db_tables(nil, {'db' => db, 'name' => table})
      end
    end
  end

  def send(db, table, old_val, new_val)
    event = LogStash::Event.new(
      "db" => db,
      "table" => table,
      "old_val" => old_val,
      "new_val" => new_val
    )
    decorate(event)
    @queue << event
  end

  def update_db_tables(old_val, new_val)
    unless new_val.nil?
      handler = TableHandler.new(new_val['db'], new_val['name'], self)
      create_table_feed(new_val['db'], new_val['name'], handler)
    end
    unless old_val.nil?
      unregister_table(old_val['db'], old_val['name'], nil)
    end
  end

  def register_table(db, table, qhandle)
    # Add a table feed to the registry
    unless @table_feeds.has_key?(db) &&
           @table_feeds[db].has_key?(table)
      @logger.log("Watching table #{db}.#{table}")
      @table_feeds[db][table] = qhandle
    else
      qhandle.close
    end
  end

  def unregister_table(db, table, qhandle)
    # Remove a table from the registry.
    if @table_feeds.has_key?(db) &&
       @table_feeds[db].has_key?(table) &&
       # If a duplicate feed comes in for the same table and needs to
       # be unregistered, we need to check if the handle is the same
       (qhandle.nil? || @table_feeds[db][table].equal?(qhandle))
      @logger.log("Unregistering table #{db}.#{table}")
      @table_feeds[db].delete(table).close
    end
  end

  def register_db(db, qhandle)
    # Add a db to the registry to watch it for updates to which tables
    # are listed in it.
    unless @db_feeds.has_key? db
      @db_feeds[db] = qhandle
      @logger.log "Feed for db '#{db}' registered"
    end
  end

  def unregister_db(db)
    # Remove a db from the registry, close all of its feeds, and
    # remove its entry in @db_admin_tables
    if @table_feeds.has_key?(db)
      @logger.log("Unregistering feed for db '#{db}'")
      @table_feeds[db].keys.each do |table|
        unregister_table(db, table, nil)
      end
      @table_feeds.delete(db)
      @db_feeds.delete(db).close
    end
  end

  def create_db_feed(db, handler)
    r.db('rethinkdb').
      table('table_status').
      changes(:include_initial => @backfill,
              :squash => @squash,
              :include_states => true).
      # The filter and pluck are after .changes due to bug #5241. When
      # that's solved they can be moved before .changes and can be
      # simplified since they won't have to operate over both new_val
      # and old_val
      filter{|row| r([row['old_val']['db'], row['new_val']['db']]).contains(db).
              and(row['status']['all_replicas_ready'])}.
      pluck({:new_val => ['db', 'name'], :old_val => ['db', 'name']}).
      em_run(@conn, handler)
  end

  def create_table_feed(db, table, handler)
    options = {
      :time_format => 'raw',
      :binary_format => 'raw',
    }
    r.db(db).
      table(table).
      changes(:include_initial => @backfill,
              :squash => @squash,
              :include_states => true).
      em_run(@conn, options, handler)
  end

  def teardown
    # Goes through all existing handles and closes them, then clears
    # out the registry and closes the connection to RethinkDB
    @table_feeds.values.each do |tables|
      tables.values.each { |qhandle| qhandle.close }
    end
    @db_feeds.values.each { |qhandle| qhandle.close }
    @table_feeds.clear
    @db_feeds.clear
    @conn.close
    EM.stop
    @queue = nil
  end

end

# This handles feeds listening for changes to documents in a table
class TableHandler < RethinkDB::Handler
  attr_accessor :db
  attr_accessor :table
  def initialize(db, table, plugin)
    super()
    @db = db
    @table = table
    @plugin = plugin
  end

  def on_initial_val(val)
    @plugin.send(@db, @table, nil, val)
  end

  def on_change(old_val, new_val)
    @plugin.send(@db, @table, old_val, new_val)
  end

  def on_open(qhandle)
    @plugin.register_table(@db, @table, qhandle)
  end

  def on_close(qhandle)
    @plugin.unregister_table(@db, @table, qhandle)
  end

  def on_error(err, qhandle)
    @plugin.logger.error(err.to_s)
    @plugin.unregister_table(@db, @table, qhandle)
  end

  def on_change_error(err_str)
    @plugin.logger.warn(err.to_s)
  end
end

# Handler for changes to the tables in a database
class DBHandler < RethinkDB::Handler

  attr_accessor :db

  def initialize(db, plugin)
    super()
    @db = db
    @plugin = plugin
  end

  def on_open(qhandle)
    @plugin.register_db(@db, qhandle)
  end

  def on_close(qhandle)
    @plugin.unregister_db(@db)
  end

  def on_error(err, qhandle)
    @plugin.logger.error(err.to_s)
    @plugin.unregister_db(@db)
  end

  def on_change_error(err_str)
    @plugin.logger.warn(err_str)
  end

  def on_initial_val(val)
    @plugin.update_db_tables(nil, val)
  end

  def on_change(old_val, new_val)
    @plugin.update_db_tables(old_val, new_val)
  end
end
