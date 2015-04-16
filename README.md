# RethinkDB Logstash input plugin

This is a plugin for [Logstash](https://github.com/elasticsearch/logstash).

**Currently this is BETA software. It includes some limitations that won't make it suitable for use in production until RethinkDB 2.1 is released**

This plugin will eventually replace the [RethinkDB river](https://github.com/rethinkdb/elasticsearch-river-rethinkdb) as the preferred method of syncing RethinkDB and ElasticSearch. We're hoping to get early feedback on how useful the plugin is, and what can be improved (beyond the known limitations, see below).


## Using the plugin

You'll need to use this with the Logstash 1.5 release candidate, which you can [download here](https://www.elastic.co/downloads/logstash).

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
    }}
output {stdout {codec => json_lines}}'
```

This will immediately watch the tables `test.foo` and `db2.baz`, and it will also watch the databases `db1` and `db2` for new or dropped tables and watch or unwatch those tables appropriately.

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

There are two big limitations that prevent this plugin from being useful for production:

1. Until RethinkDB supports `return_initial` on all changefeeds ([which it should in 2.1](https://github.com/rethinkdb/rethinkdb/issues/3579)), this plugin won't do "backfilling" of documents already in a table. It only sends changes to the table as they are received. When `return_initial` is implemented fully, this plugin will be updated to take advantage of that capability to provide backfilling.
2. Until RethinkDB supports resuming changefeeds ([which it should in 2.1](https://github.com/rethinkdb/rethinkdb/issues/3471)), this plugin cannot guarantee that no changes are missed if a connection to the database is dropped. Again, once that functionality is implemented, this plugin will be modified to provide reliable "at least once" semantics for changes (meaning once it reconnects, it can catch back up and send any changes that it missed).

## License

Apache 2.0
