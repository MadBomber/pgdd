# frozen_string_literal: true

module Pgdd
  # Everything the Collector learns about an application, as plain values.
  # Report and ErdWriter consume these; nothing below depends on Rails.
  App = Data.define(:name, :root, :environment, :rails_version, :ruby_version, :databases, :models)

  Database = Data.define(:name, :adapter, :location, :server_version, :schema_version,
                         :pending_migrations, :extensions, :enums, :tables, :migrations, :error) do
    def initialize(name:, adapter: nil, location: nil, server_version: nil, schema_version: nil,
                   pending_migrations: nil, extensions: [], enums: {}, tables: [], migrations: [], error: nil)
      super
    end
  end

  Table = Data.define(:name, :kind, :comment, :primary_key, :columns, :indexes, :foreign_keys,
                      :check_constraints, :triggers, :rows, :rows_estimated, :bytes) do
    def initialize(name:, kind: 'table', comment: nil, primary_key: nil, columns: [], indexes: [],
                   foreign_keys: [], check_constraints: [], triggers: [], rows: nil,
                   rows_estimated: false, bytes: nil)
      super
    end
  end

  Column     = Data.define(:name, :sql_type, :null, :default, :comment) do
    def initialize(name:, sql_type:, null: true, default: nil, comment: nil)
      super
    end
  end
  Index      = Data.define(:name, :columns, :unique, :where, :using) do
    def initialize(name:, columns:, unique: false, where: nil, using: nil)
      super
    end
  end
  ForeignKey = Data.define(:name, :column, :to_table, :primary_key, :on_delete, :on_update) do
    def initialize(column:, to_table:, name: nil, primary_key: 'id', on_delete: nil, on_update: nil)
      super
    end
  end
  Constraint = Data.define(:name, :expression)
  Trigger    = Data.define(:name, :timing, :events, :action)

  # One migration file: tables maps each table it touches to the changes made
  # to it, in file order; renames lists [old_name, new_name] pairs
  Migration = Data.define(:version, :name, :path, :tables, :renames) do
    def initialize(version:, name:, path:, tables: {}, renames: [])
      super
    end
  end

  Model = Data.define(:name, :table_name, :database, :source, :sti_parent, :sti_column,
                      :associations, :enums, :validations, :stored_attributes, :attachments,
                      :encrypted_attributes, :virtual_attributes, :error) do
    def initialize(name:, table_name: nil, database: 'primary', source: nil, sti_parent: nil,
                   sti_column: nil, associations: [], enums: {}, validations: [],
                   stored_attributes: {}, attachments: [], encrypted_attributes: [],
                   virtual_attributes: [], error: nil)
      super
    end
  end

  Association = Data.define(:macro, :name, :class_name, :foreign_key, :options) do
    def initialize(macro:, name:, class_name: nil, foreign_key: nil, options: {})
      super
    end
  end
  Validation = Data.define(:kind, :attributes, :options) do
    def initialize(kind:, attributes:, options: {})
      super
    end
  end
end
