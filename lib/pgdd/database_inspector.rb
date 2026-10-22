# frozen_string_literal: true

module Pgdd
  # Reads everything it can about one database through an ActiveRecord connection
  class DatabaseInspector
    INTERNAL_TABLES = %w[schema_migrations ar_internal_metadata].freeze

    def initialize(connection, name:, root: Dir.pwd, count_rows: false, include_internal: false)
      @connection       = connection
      @name             = name
      @root             = root
      @count_rows       = count_rows
      @include_internal = include_internal
    end

    def call
      Database.new(
        name:               @name,
        adapter:            @connection.adapter_name,
        location:           location,
        server_version:     server_version,
        schema_version:     schema_version,
        pending_migrations: pending_migrations,
        migrations:         migrations,
        extensions:         extensions,
        enums:              enums,
        tables:             data_sources.map { |name, kind| table(name, kind) }
      )
    end

    def postgres? = @connection.adapter_name.match?(/postg/i)
    def sqlite?   = @connection.adapter_name.match?(/sqlite/i)

    # [[name, kind], ...] for every table and view
    def data_sources
      sources = @connection.tables.map { |name| [name, 'table'] } +
                @connection.views.map { |name| [name, materialized_views.include?(name) ? 'materialized view' : 'view'] }
      sources.reject! { |name, _| INTERNAL_TABLES.include?(name) } unless @include_internal
      sources.sort
    end

    def table(name, kind)
      Table.new(
        name:              name,
        kind:              kind,
        comment:           table_comment(name),
        primary_key:       @connection.primary_key(name),
        columns:           columns(name),
        indexes:           indexes(name),
        foreign_keys:      foreign_keys(name),
        check_constraints: check_constraints(name),
        triggers:          triggers.fetch(name) { [] },
        **row_stats(name, kind)
      )
    end

    def columns(table_name)
      @connection.columns(table_name).map do |c|
        sql_type = c.sql_type.to_s
        sql_type += '[]' if c.respond_to?(:array?) && c.array?
        Column.new(
          name:     c.name,
          sql_type: sql_type,
          null:     c.null,
          default:  c.default_function || c.default,
          comment:  c.respond_to?(:comment) ? c.comment : nil
        )
      end
    end

    def indexes(table_name)
      @connection.indexes(table_name).map do |i|
        Index.new(name: i.name, columns: Array(i.columns), unique: i.unique, where: i.where, using: i.using)
      end
    end

    def foreign_keys(table_name)
      return [] unless @connection.supports_foreign_keys?

      @connection.foreign_keys(table_name).map do |fk|
        ForeignKey.new(name: fk.name, column: fk.column, to_table: fk.to_table,
                       primary_key: fk.primary_key, on_delete: fk.on_delete, on_update: fk.on_update)
      end
    end

    def check_constraints(table_name)
      return [] unless @connection.respond_to?(:supports_check_constraints?) && @connection.supports_check_constraints?

      @connection.check_constraints(table_name).map { |c| Constraint.new(name: c.name, expression: c.expression) }
    end

    def table_comment(table_name)
      @connection.table_comment(table_name) if @connection.supports_comments?
    end

    def row_stats(table_name, kind)
      stats = relation_stats.fetch(table_name) { {} }
      rows  = stats[:rows]

      if @count_rows && kind != 'view'
        rows = @connection.select_value("SELECT COUNT(*) FROM #{@connection.quote_table_name(table_name)}").to_i
        return { rows: rows, rows_estimated: false, bytes: stats[:bytes] }
      end

      { rows: rows, rows_estimated: !rows.nil?, bytes: stats[:bytes] }
    end

    # { table_name => { rows:, bytes: } }; rows are planner estimates
    def relation_stats
      @relation_stats ||=
        if postgres? then postgres_relation_stats
        elsif sqlite? then sqlite_relation_stats
        else {}
        end
    end

    def postgres_relation_stats
      sql = <<~SQL
        SELECT c.relname AS name, c.reltuples::bigint AS rows, pg_total_relation_size(c.oid) AS bytes
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'p', 'm') AND n.nspname = ANY (current_schemas(false))
      SQL
      @connection.select_all(sql).to_h do |row|
        rows = row['rows'].to_i
        [row['name'], { rows: rows.negative? ? nil : rows, bytes: row['bytes'].to_i }]
      end
    end

    # Needs SQLite compiled with the dbstat virtual table; sizes include indexes
    def sqlite_relation_stats
      sql = <<~SQL
        SELECT m.tbl_name AS name, SUM(d.pgsize) AS bytes
          FROM dbstat d JOIN sqlite_master m ON m.name = d.name
         GROUP BY m.tbl_name
      SQL
      @connection.select_all(sql).to_h { |row| [row['name'], { bytes: row['bytes'].to_i }] }
    rescue ActiveRecord::StatementInvalid
      {}
    end

    # { table_name => [Trigger, ...] }
    def triggers
      @triggers ||=
        if postgres? then postgres_triggers
        elsif sqlite? then sqlite_triggers
        else {}
        end
    end

    def postgres_triggers
      sql = <<~SQL
        SELECT event_object_table AS table_name, trigger_name, action_timing,
               string_agg(event_manipulation, ' OR ' ORDER BY event_manipulation) AS events,
               action_statement
          FROM information_schema.triggers
         WHERE trigger_schema = ANY (current_schemas(false))
         GROUP BY event_object_table, trigger_name, action_timing, action_statement
         ORDER BY 1, 2
      SQL
      @connection.select_all(sql).group_by { |r| r['table_name'] }.transform_values do |rows|
        rows.map { |r| Trigger.new(name: r['trigger_name'], timing: r['action_timing'], events: r['events'], action: r['action_statement']) }
      end
    end

    def sqlite_triggers
      sql = "SELECT tbl_name, name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY tbl_name, name"
      @connection.select_all(sql).group_by { |r| r['tbl_name'] }.transform_values do |rows|
        rows.map { |r| Trigger.new(name: r['name'], timing: nil, events: nil, action: r['sql']) }
      end
    end

    def materialized_views
      @materialized_views ||=
        postgres? ? @connection.select_values('SELECT matviewname FROM pg_matviews WHERE schemaname = ANY (current_schemas(false))') : []
    end

    # { enum_type_name => [values] } for PostgreSQL enum types
    def enums
      return {} unless postgres?

      sql = <<~SQL
        SELECT t.typname AS name, string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) AS labels
          FROM pg_type t
          JOIN pg_enum e ON e.enumtypid = t.oid
          JOIN pg_namespace n ON n.oid = t.typnamespace
         WHERE n.nspname = ANY (current_schemas(false))
         GROUP BY t.typname ORDER BY 1
      SQL
      @connection.select_all(sql).to_h { |r| [r['name'], r['labels'].split(',')] }
    end

    def extensions
      @connection.respond_to?(:extensions) ? @connection.extensions.sort : []
    end

    def location
      @connection.pool.db_config.database
    rescue StandardError
      nil
    end

    def server_version
      sql = if postgres? then 'SHOW server_version'
            elsif sqlite? then 'SELECT sqlite_version()'
            else 'SELECT version()'
            end
      @connection.select_value(sql)
    rescue StandardError
      nil
    end

    def schema_version
      migration_context&.current_version
    rescue StandardError
      nil
    end

    def pending_migrations
      migration_context&.needs_migration?
    rescue StandardError
      nil
    end

    # Every migration file on this database's migrations paths, oldest first
    def migrations
      MigrationScanner.new(migrations_paths, root: @root).call
    end

    def migrations_paths
      Array(migration_context&.migrations_paths)
    rescue StandardError
      []
    end

    def migration_context
      pool = @connection.pool
      return pool.migration_context if pool.respond_to?(:migration_context)

      @connection.migration_context if @connection.respond_to?(:migration_context)
    end
  end
end
