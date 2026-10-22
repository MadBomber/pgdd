# frozen_string_literal: true

module Pgdd
  # Reads the already-booted Rails application's databases and models into
  # an App. Only reads: callers wrap it in while_preventing_writes.
  class Collector
    def initialize(root:, count_rows: false, include_internal: false, databases: [], all_databases: false)
      @root             = root
      @count_rows       = count_rows
      @include_internal = include_internal
      @databases        = databases
      @all_databases    = all_databases
    end

    def call
      configs = database_configs(@databases, all: @all_databases)
      missing = configs.to_h { |c| [c.name, missing_sqlite_file(c.adapter, c.database)&.delete_prefix("#{@root}/")] }.compact
      models  = inspect_models(configs.map(&:name), missing)
      dbs     = inspect_databases(configs, missing)

      App.new(name: app_name, root: @root, environment: Rails.env.to_s, rails_version: Rails.version,
              ruby_version: RUBY_VERSION, databases: dbs, models: models)
    end

    def app_name
      app_class = Rails.application.class
      app_class.respond_to?(:module_parent_name) ? app_class.module_parent_name : app_class.parent_name
    end

    # Models on the named databases. Inspecting a model can open its
    # connection, so a model on a missing database is reported, not inspected
    def inspect_models(names, missing)
      ModelInspector.models.filter_map do |m|
        inspector = ModelInspector.new(m, root: @root)
        db_name   = inspector.database_name
        next unless names.include?(db_name)
        next Model.new(name: m.name, table_name: m.table_name, database: db_name, error: "database file not found: #{missing[db_name]}") if missing[db_name]

        inspector.call
      end
    end

    # A Database per config; one that cannot be read is returned with its error
    def inspect_databases(configs, missing)
      database_connections(configs).map do |name, klass|
        missing[name] ? missing_database(name, klass, missing[name]) : inspect_database(name, klass)
      rescue StandardError => e
        Database.new(name: name, error: "#{e.class}: #{e.message.lines.first&.strip}")
      end
    end

    def missing_database(name, klass, file)
      config = klass.connection_db_config
      Database.new(name: name, adapter: config.adapter, location: config.database, error: "database file not found: #{file}")
    end

    def inspect_database(name, klass)
      with_connection(klass) do |connection|
        DatabaseInspector.new(connection, name: name, root: @root, count_rows: @count_rows, include_internal: @include_internal).call
      end
    end

    # The configs to report: the ones named, or all of them, or just the primary
    def database_configs(only = [], all: false)
      configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
      configs = configs.reject { |c| c.respond_to?(:replica?) && c.replica? }
      return configs.select { |c| only.include?(c.name) } if only.any?
      return configs if all

      primary = ActiveRecord::Base.connection_db_config.name
      configs.select { |c| c.name == primary }
    end

    # [[config_name, connection_class], ...]; a secondary database gets an
    # abstract class of its own, reused if one was already made for it
    def database_connections(configs)
      primary = ActiveRecord::Base.connection_db_config.name

      configs.map do |config|
        next [config.name, ActiveRecord::Base] if config.name == primary

        [config.name, connection_class_for(config.name)]
      end
    end

    def connection_class_for(config_name)
      const = :"Connection#{config_name.to_s.gsub(/\W/, '_').capitalize}"
      return self.class.const_get(const, false) if self.class.const_defined?(const, false)

      klass = self.class.const_set(const, Class.new(ActiveRecord::Base) { self.abstract_class = true })
      klass.establish_connection(config_name.to_sym)
      klass
    end

    # Connecting to a missing SQLite file would create an empty one
    def missing_sqlite_file(adapter, database)
      return nil unless adapter.to_s.start_with?('sqlite') && database && !database.start_with?(':memory:', 'file:')

      path = File.expand_path(database, @root)
      path unless File.exist?(path)
    end

    def with_connection(klass, &)
      return klass.with_connection(&) if klass.respond_to?(:with_connection)

      yield klass.connection
    end
  end
end
