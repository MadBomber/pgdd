# frozen_string_literal: true

module Pgdd
  # Reads what the application code says about one ActiveRecord model
  class ModelInspector
    SHOWN_OPTIONS = %i[through source source_type as polymorphic dependent inverse_of
                       counter_cache optional required touch primary_key foreign_type
                       autosave validate].freeze
    ACTIVE_STORAGE = %w[ActiveStorage::Attachment ActiveStorage::Blob].freeze

    def self.models
      Rails.application.eager_load!
      ActiveRecord::Base.descendants.select { |m| reportable?(m) }.sort_by(&:name)
    end

    def self.reportable?(model)
      name = model.name
      return false if name.nil? || model.abstract_class?

      !name.include?('HABTM_') && !name.start_with?('ActiveRecord::', 'Pgdd::')
    end

    def initialize(model, root: Dir.pwd)
      @model = model
      @root  = root
    end

    def call
      Model.new(
        name:                 @model.name,
        table_name:           @model.table_name,
        database:             database_name,
        source:               source,
        sti_parent:           sti_parent,
        sti_column:           sti_column,
        associations:         associations,
        **own_definitions
      )
    rescue StandardError => e
      Model.new(name: @model.name, table_name: (@model.table_name rescue nil), error: "#{e.class}: #{e.message}")
    end

    # Definitions that can be inherited; an STI subclass only reports what it adds
    def definitions
      {
        enums:                enums,
        validations:          validations,
        stored_attributes:    stored_attributes,
        attachments:          attachments,
        encrypted_attributes: encrypted_attributes,
        virtual_attributes:   virtual_attributes
      }
    end

    def own_definitions
      mine = definitions
      return mine unless sti_parent

      inherited = self.class.new(@model.superclass, root: @root).definitions
      mine.to_h { |key, value| [key, value.is_a?(Hash) ? value.reject { |k, v| inherited[key][k] == v } : value - inherited[key]] }
    end

    def database_name
      @model.connection_db_config.name
    rescue StandardError
      'primary'
    end

    def source
      path = Object.const_source_location(@model.name)&.first
      return nil unless path

      path = File.expand_path(path)
      return path.delete_prefix("#{@root}/") if path.start_with?("#{@root}/")

      path[%r{/gems/(.+)}, 1] || path
    end

    def sti_parent
      @model.superclass.name unless @model.base_class == @model
    end

    # The inheritance column, when this model is the base of an STI hierarchy
    def sti_column
      column = @model.inheritance_column
      return nil unless @model.base_class == @model && @model.descendants.any?

      column if @model.column_names.include?(column)
    rescue StandardError
      nil
    end

    def associations
      inherited = sti_parent ? @model.superclass.reflect_on_all_associations.map(&:name) : []

      @model.reflect_on_all_associations.filter_map do |r|
        next if inherited.include?(r.name) || ACTIVE_STORAGE.include?(r.options[:class_name].to_s)

        options = r.options.slice(*SHOWN_OPTIONS)
        options[:scope] = :lambda if r.scope
        Association.new(
          macro:       r.macro,
          name:        r.name,
          class_name:  r.polymorphic? ? nil : r.class_name,
          foreign_key: (r.options[:through] ? nil : (r.foreign_key rescue nil)),
          options:     options
        )
      end
    end

    # { attribute => { key => stored_value } }
    def enums
      @model.defined_enums.transform_values(&:to_h)
    end

    def validations
      validators = @model.validators.map do |v|
        Validation.new(kind: v.kind, attributes: v.attributes.map(&:to_s), options: v.options)
      end
      validators + custom_validations
    end

    # `validate :method_name` style validations, skipping the ones Rails adds itself
    def custom_validations
      @model._validate_callbacks.map(&:filter).grep(Symbol).filter_map do |name|
        next if rails_method?(name)

        Validation.new(kind: :validate, attributes: [name.to_s], options: {})
      end
    rescue StandardError
      []
    end

    def rails_method?(name)
      path = @model.instance_method(name).source_location&.first.to_s
      path.match?(%r{/(activerecord|activemodel|activesupport)-[^/]+/})
    rescue NameError
      false
    end

    def stored_attributes
      @model.stored_attributes.to_h { |store, keys| [store.to_s, keys.map(&:to_s)] }
    end

    def attachments
      return [] unless @model.respond_to?(:reflect_on_all_attachments)

      @model.reflect_on_all_attachments.map { |a| "#{a.name} (#{a.macro})" }
    end

    def encrypted_attributes
      @model.respond_to?(:encrypted_attributes) ? @model.encrypted_attributes.to_a.map(&:to_s) : []
    end

    # Attributes declared with the attribute API that have no database column
    def virtual_attributes
      @model.attribute_types.keys - @model.column_names
    rescue StandardError
      []
    end
  end
end
