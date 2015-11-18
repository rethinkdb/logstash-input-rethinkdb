# RethinkDB Logstash input plugin

This is a plugin for [Logstash](https://github.com/elasticsearch/logstash).

**Currently this is BETA software. It contains some known limitations (see below)**

## Using the plugin

You'll need to use this with the Logstash 1.5 or higher, which you can [download here](https://www.elastic.co/downloads/logstash).

- Install the plugin from the Logstash home directory
```sh
$ bin/plugin install logstash-input-rethinkdb
```

- Now you can test the plugin using the stdout output:

```sh
$ bin/logstash -e '
input {rethinkdb
   {host => "localhost"
    port => 28015
    auth_key => ""
    watch_dbs => ["db1", "db2"]
    watch_tables => ["test.foo", "db2.baz"]
    backfill => true
    }}
output {stdout {codec => json_lines}}'
```

This will immediately watch the tables `test.foo` and `db2.baz`, and it will also watch the databases `db1` and `db2` for new or dropped tables and watch or unwatch those tables appropriately. Since `backfill` is `true`, it will automatically send events for the documents that already exist in those tables during initialization.

### Format of the events:

The events are encoded with the "json_lines" codec, which puts compressed json documents one event per line

Fields:

- **db**: the database that emitted the event
- **table**: the table that emitted the event
- **old_val**: the old value of the document (see [changefeeds](http://rethinkdb.com/docs/changefeeds/ruby/))
- **new_val**: the new value of the document
- **@timestamp**: timestamp added by logstash (so may not correspond to the rethinkdb server time the change was emitted)
- **@version**: version number added by logstash (always 1)

## Known limitations

There are two limitations that should be known by anyone using this in production systems:

1. Until RethinkDB supports resuming changefeeds, this plugin cannot guarantee that no changes are missed if a connection to the database is dropped. Again, once that functionality is implemented, this plugin will be modified to provide reliable "at least once" semantics for changes (meaning once it reconnects, it can catch back up and send any changes that it missed).
2. Documents that are deleted in RethinkDB while the LogStash plugin is disconnected will not be synchronized. This is true even if `backfill` is enabled. This limitation is a consequence of LogStash operating on a document-by-document basis.

## License

Apache 2.0
