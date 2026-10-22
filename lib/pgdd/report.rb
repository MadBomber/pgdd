# frozen_string_literal: true

module Pgdd
  # Builds the Markdown database documentation from an App: the index page and one
  # page per table. Needs nothing from Rails; everything comes from the App.
  class Report
    class << self
      def cell(value)
        value.to_s.gsub('|', '\|').gsub(/\s*\n\s*/, ' ')
      end

      # Columns are padded so the pipes line up (markdownlint MD060 "aligned")
      def markdown_table(headers, rows)
        cells  = ([headers] + rows).map { |row| row.map { |v| cell(v) } }
        widths = cells.transpose.map { |column| [column.map(&:length).max, 3].max }
        lines  = cells.map { |row| row.zip(widths).map { |v, width| v.ljust(width) } }
        lines.insert(1, widths.map { |width| '-' * width })
        lines.map { |row| "| #{row.join(' | ')} |" }.join("\n")
      end

      def format_version(version)
        digits = version.to_s.delete('_')
        return 'unknown' if digits.empty? || digits == '0'

        m = digits.match(/\A(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)\z/)
        m ? "#{m[1]}-#{m[2]}-#{m[3]} #{m[4]}:#{m[5]}:#{m[6]} (#{digits})" : digits
      end

      def format_value(value)
        case value
        when Proc   then '(proc)'
        when Array  then value.map { |v| format_value(v) }.join(', ')
        when Hash   then "{#{format_options(value)}}"
        when String then value
        else value.inspect
        end
      end

      def format_options(options)
        options.map { |key, value| "#{key}: #{format_value(value)}" }.join(', ')
      end

      def enum_values(mapping)
        mapping.map { |key, value| key.to_s == value.to_s ? key.to_s : "#{key} (#{value})" }.join(', ')
      end

      def number(value)
        value.to_s.reverse.scan(/\d{1,3}/).join(',').reverse.then { |s| value.negative? ? "-#{s}" : s }
      end

      def human_size(bytes)
        return '' if bytes.nil?

        units = %w[B KB MB GB TB]
        size  = bytes.to_f
        unit  = 0
        while size >= 1024 && unit < units.size - 1
          size /= 1024
          unit += 1
        end
        unit.zero? ? "#{bytes} B" : format('%<size>.1f %<unit>s', size: size, unit: units[unit])
      end

      def rows_label(table)
        return '' if table.rows.nil?

        table.rows_estimated ? "~#{number(table.rows)}" : number(table.rows)
      end
    end

    INDEX    = 'INDEX.md'
    README   = 'README.md'
    TEMPLATE = File.expand_path('readme_template.md', __dir__)

    # erd_format names the diagram files the table pages embed; nil for none.
    # output_dir is where the pages will be written; migration links are relative to it.
    # command is the command line that produced the report, quoted in the README
    def initialize(app, date: Date.today, erd_format: nil, output_dir: nil, command: 'pgdd')
      @app        = app
      @date       = date
      @erd_format = erd_format
      @output_dir = output_dir
      @command    = command
      @multi      = app.databases.size > 1
      @models     = app.models.group_by { |m| [m.database, m.table_name] }
    end

    # { filename => markdown } for the README, the index page and one page per table
    def pages
      pages = { README => readme, INDEX => index_markdown }
      @app.databases.reject(&:error).each do |db|
        db.tables.each { |t| pages["#{basename(db.name, t.name)}.md"] = table_page(db, t) }
      end
      pages
    end

    # The directory's README from readme_template.md: what the files are, how to
    # read the diagrams, and how this copy was generated
    def readme
      image    = %w[svg png].include?(@erd_format)
      template = ERB.new(File.read(TEMPLATE), trim_mode: '-')
      template.result_with_hash(
        app: @app, date: @date, index: INDEX, command: @command, multi: @multi,
        erd_format: @erd_format, image: image, files_table: readme_files_table(image),
        schema_stem: @multi ? '<database>.schema' : 'schema'
      )
    end

    # The README's table of what each file in the directory is
    def readme_files_table(image)
      pattern = @multi ? '<database>.<table>' : '<table>'
      rows = [
        ["`#{INDEX}`", 'The index. Databases, tables, enum types, models without a table, and the data element index.'],
        ["`#{pattern}.md`", 'One page per table: columns, indexes, foreign keys, the tables that reference it, ' \
                            'check constraints, triggers, the migrations that changed it, and the models backed by the table.']
      ]
      if @erd_format
        rows << ["`#{pattern}.#{@erd_format}`", "The entity relationship diagram for that table#{', embedded in its page' if image}."]
        rows << ["`#{'<database>.' if @multi}schema.#{@erd_format}`", 'One diagram of every table in the database.']
      end
      self.class.markdown_table(%w[File Content], rows)
    end

    def index_markdown
      sections = [header, database_summary]
      @app.databases.each { |db| sections << database_section(db) }
      sections << orphan_models
      sections << data_element_index
      sections.compact.join("\n\n") + "\n"
    end

    # File stem shared by a table's page and its diagram; prefixed when there are several databases
    def basename(db_name, table_name)
      @multi ? "#{db_name}.#{table_name}" : table_name
    end

    def page_link(db_name, table_name)
      "[#{table_name}](#{basename(db_name, table_name)}.md)"
    end

    def header
      <<~HEADER.chomp
        # #{@app.name} Database Documentation

        This report was generated on #{@date} by booting the application and
        reading its live database#{'s' if @multi} and its ActiveRecord models.

        - **Application:** #{@app.name} (`#{File.basename(@app.root)}`)
        - **Environment:** #{@app.environment}
        - **Rails:** #{@app.rails_version}
        - **Ruby:** #{@app.ruby_version}
        - **Models:** #{@app.models.size}
      HEADER
    end

    def database_summary
      headers = ['Database', 'Adapter', 'Server Version', 'Location', 'Schema Version', 'Tables', 'Views', 'Models']
      rows = @app.databases.map do |db|
        tables, views = db.tables.partition { |t| t.kind == 'table' }
        model_count   = @app.models.count { |m| m.database == db.name }
        [db.name, db.adapter, db.server_version, db.location, self.class.format_version(db.schema_version),
         tables.size, views.size, model_count]
      end

      warnings = @app.databases.filter_map do |db|
        if db.error
          "> **#{db.name}:** could not be read: #{db.error}"
        elsif db.pending_migrations
          "> **#{db.name}:** has pending migrations; the database may not match the migration files."
        end
      end

      # One blockquote; separate quotes with blank lines between them trip MD028
      parts = ['## Databases', self.class.markdown_table(headers, rows)]
      parts << warnings.join("\n>\n") if warnings.any?
      parts.join("\n\n")
    end

    def database_section(db)
      return nil if db.error

      parts = ["## #{@multi ? "#{db.name} Database" : 'Database'} Tables"]
      parts << "**Extensions:** #{db.extensions.join(', ')}" if db.extensions.any?
      parts << table_summary(db)
      if db.enums.any?
        rows = db.enums.map { |name, values| [name, values.join(', ')] }
        parts << "### #{"#{db.name} " if @multi}Enum Types\n\n#{self.class.markdown_table(%w[Name Values], rows)}"
      end
      parts.join("\n\n")
    end

    def table_summary(db)
      described = db.tables.any?(&:comment)
      headers   = %w[Table Kind Models Rows Size]
      headers << 'Description' if described

      rows = db.tables.map do |t|
        row = [page_link(db.name, t.name), t.kind,
               models_for(db, t).map(&:name).join(', '), self.class.rows_label(t), self.class.human_size(t.bytes)]
        row << t.comment if described
        row
      end
      self.class.markdown_table(headers, rows)
    end

    def heading(db, table)
      basename(db.name, table.name)
    end

    def models_for(db, table)
      @models.fetch([db.name, table.name]) { [] }
    end

    def table_page(db, t)
      parts = ["# #{heading(db, t)}", t.comment, table_facts(t), diagram_section(db, t)]
      parts.concat(schema_sections(db, t))
      parts << migrations_section(db, t)
      parts.concat(models_for(db, t).map { |m| model_detail(m) })
      parts << "[Back to the index](#{INDEX})"
      parts.compact.join("\n\n") + "\n"
    end

    def table_facts(t)
      facts = ["**Kind:** #{t.kind}"]
      facts << "**Primary key:** #{Array(t.primary_key).join(', ')}" if t.primary_key
      facts << "**Rows:** #{self.class.rows_label(t)}#{' (estimate)' if t.rows_estimated}" if t.rows
      facts << "**Size:** #{self.class.human_size(t.bytes)}" if t.bytes
      facts.join(' · ')
    end

    # Columns, indexes, keys, constraints and triggers; a section with nothing to list is nil
    def schema_sections(db, t)
      ["## Columns\n\n#{columns_table(t)}",
       section('Indexes', t.indexes) { indexes_table(t) },
       section('Foreign Keys', t.foreign_keys) { foreign_keys_table(db, t) },
       section('Referenced By', referencing_keys(db, t)) { |keys| referenced_by_table(db, keys) },
       section('Check Constraints', t.check_constraints) { |constraints| constraints_table(constraints) },
       section('Triggers', t.triggers) { |triggers| triggers_table(triggers) }]
    end

    # A heading over the table the block builds from items, or nil when items is empty
    def section(title, items, level: '##')
      return nil if items.empty?

      "#{level} #{title}\n\n#{yield(items)}"
    end

    def referenced_by_table(db, keys)
      rows = keys.map { |from, fk| [page_link(db.name, from), Array(fk.column).join(', '), fk.on_delete, fk.name] }
      self.class.markdown_table(['Table', 'Column', 'On Delete', 'Name'], rows)
    end

    def constraints_table(constraints)
      self.class.markdown_table(%w[Name Expression], constraints.map { |c| [c.name, "`#{c.expression}`"] })
    end

    def triggers_table(triggers)
      rows = triggers.map { |tr| [tr.name, [tr.timing, tr.events].compact.join(' '), "`#{tr.action}`"] }
      self.class.markdown_table(%w[Name When Action], rows)
    end

    # The ErdWriter for a database, shared with the related-tables list so the
    # page and its diagram agree on what is related
    def erd_for(db)
      @erds ||= {}
      @erds[db.name] ||= ErdWriter.new(db, models: @app.models.select { |m| m.database == db.name })
    end

    # Linked lists of the tables this one references and the tables that
    # reference it, foreign keys and polymorphic associations alike. Markdown
    # renderers show the diagram as a static image, so this is the navigation
    # the diagram's own links would give.
    def related_tables(db, t)
      references = []
      referenced = []
      erd_for(db).relations(t).each do |from, key|
        column = Array(key.column).join(', ')
        note   = key.is_a?(ErdWriter::PolymorphicKey) ? ' (polymorphic)' : ''
        if from == t.name
          references << "- #{page_link(db.name, key.to_table)} via `#{column}`#{note}"
        else
          referenced << "- #{page_link(db.name, from)} via `#{column}`#{note}"
        end
      end
      return nil if references.empty? && referenced.empty?

      parts = []
      parts << "**References:**\n\n#{references.uniq.join("\n")}" if references.any?
      parts << "**Referenced by:**\n\n#{referenced.uniq.join("\n")}" if referenced.any?
      parts.join("\n\n")
    end

    # The Relations section: the related-tables list and, when the ERD is an
    # image format, the diagram. GitHub and most Markdown renderers show the
    # image statically, so the links inside the SVG only work when it is opened
    # from a checkout; the list above it is the navigation that always works.
    def diagram_section(db, t)
      parts = ['## Relations']
      parts << (related_tables(db, t) || 'No other table is related to this one.')
      if %w[svg png].include?(@erd_format)
        file = "#{basename(db.name, t.name)}.#{@erd_format}"
        parts << "![#{t.name} entity relationship diagram](#{file})"
        parts << 'Solid edges are database foreign keys; dashed edges are polymorphic associations the models declare. ' \
                 'The table names in the diagram are links, but only when the SVG is opened on its own from a checkout; ' \
                 'on GitHub use the list above.'
      end
      parts.join("\n\n")
    end

    def columns_table(t)
      described = t.columns.any?(&:comment)
      headers   = %w[Column Type Null Default Key]
      headers << 'Description' if described

      rows = t.columns.map do |c|
        row = [c.name, c.sql_type, c.null ? 'YES' : 'NO', c.default, column_keys(t, c.name)]
        row << c.comment if described
        row
      end
      self.class.markdown_table(headers, rows)
    end

    # "PK", "FK → table", "UQ" markers for a column
    def column_keys(t, column_name)
      keys = []
      keys << 'PK' if Array(t.primary_key).include?(column_name)
      t.foreign_keys.each { |fk| keys << "FK → #{fk.to_table}" if Array(fk.column).include?(column_name) }
      keys << 'UQ' if t.indexes.any? { |i| i.unique && i.columns == [column_name] }
      keys.join(', ')
    end

    def indexes_table(t)
      rows = t.indexes.map do |i|
        [i.name, i.columns.join(', '), i.unique ? 'YES' : '', i.using, i.where && "`#{i.where}`"]
      end
      self.class.markdown_table(%w[Name Columns Unique Using Condition], rows)
    end

    def foreign_keys_table(db, t)
      rows = t.foreign_keys.map do |fk|
        [Array(fk.column).join(', '), "#{page_link(db.name, fk.to_table)}.#{Array(fk.primary_key).join(', ')}", fk.on_delete, fk.on_update, fk.name]
      end
      self.class.markdown_table(['Column', 'References', 'On Delete', 'On Update', 'Name'], rows)
    end

    # [[table_name, ForeignKey], ...] for keys in other tables pointing at this one
    def referencing_keys(db, t)
      db.tables.flat_map { |other| other.foreign_keys.select { |fk| fk.to_table == t.name }.map { |fk| [other.name, fk] } }
    end

    # The table's current name plus every name it was renamed from, found by
    # walking the renames back from newest to oldest
    def table_names(db, t)
      names = [t.name]
      db.migrations.reverse_each do |m|
        m.renames.each { |old, new| names << old if names.include?(new) && !names.include?(old) }
      end
      names
    end

    # [[Migration, [change, ...]], ...] for the migrations that touched this table, oldest first
    def migrations_for(db, t)
      names = table_names(db, t)
      db.migrations.filter_map do |m|
        changes = names.flat_map { |n| m.tables.fetch(n) { [] } }
        [m, changes] if changes.any?
      end
    end

    def migration_link(m)
      return m.path unless @output_dir

      Pathname.new(m.path).relative_path_from(Pathname.new(@output_dir)).to_s
    end

    def migrations_section(db, t)
      rows = migrations_for(db, t).map do |m, changes|
        [self.class.format_version(m.version).sub(/ \(\d+\)\z/, ''),
         "[#{m.name}](#{migration_link(m)})",
         changes.map { |c| "`#{c}`" }.join(', ')]
      end
      return nil if rows.empty?

      "## Migrations\n\n#{self.class.markdown_table(['Version', 'Migration', 'Changes to this table'], rows)}"
    end

    def model_detail(m)
      return "## Model: #{m.name}\n\nCould not be inspected: #{m.error}" if m.error

      parts = ["## Model: #{m.name}", model_facts(m),
               section("#{m.name} Associations", m.associations, level: '###') { |a| associations_table(a) },
               section("#{m.name} Enums", m.enums, level: '###') { |e| enums_table(e) },
               section("#{m.name} Validations", m.validations, level: '###') { |v| validations_table(v) }]
      parts.concat(model_extras(m))
      parts.compact.join("\n\n")
    end

    def model_facts(m)
      facts = []
      facts << "**Source:** `#{m.source}`" if m.source
      facts << "**STI subclass of:** #{m.sti_parent}" if m.sti_parent
      facts << "**STI type column:** #{m.sti_column}" if m.sti_column
      facts.join(' · ') unless facts.empty?
    end

    def associations_table(associations)
      rows = associations.map do |a|
        [a.macro, a.name, a.class_name || '(polymorphic)', a.foreign_key, self.class.format_options(a.options)]
      end
      self.class.markdown_table(['Type', 'Name', 'Class', 'Foreign Key', 'Options'], rows)
    end

    def enums_table(enums)
      self.class.markdown_table(%w[Attribute Values], enums.map { |attr, mapping| [attr, self.class.enum_values(mapping)] })
    end

    def validations_table(validations)
      rows = validations.map { |v| [v.kind, v.attributes.join(', '), self.class.format_options(v.options)] }
      self.class.markdown_table(%w[Validation Attributes Options], rows)
    end

    # Store accessors, attachments, encrypted and virtual attributes, one line each
    def model_extras(m)
      extras = m.stored_attributes.map { |store, keys| "**Store `#{store}`:** #{keys.join(', ')}" }
      extras << "**Attachments:** #{m.attachments.join(', ')}" if m.attachments.any?
      extras << "**Encrypted attributes:** #{m.encrypted_attributes.join(', ')}" if m.encrypted_attributes.any?
      extras << "**Virtual attributes:** #{m.virtual_attributes.join(', ')}" if m.virtual_attributes.any?
      extras
    end

    def orphan_models
      inspected = @app.databases.reject(&:error)
      known     = inspected.flat_map { |db| db.tables.map { |t| [db.name, t.name] } }
      orphans   = @app.models.select { |m| inspected.any? { |db| db.name == m.database } }
                      .reject { |m| known.include?([m.database, m.table_name]) }
      return nil if orphans.empty?

      rows = orphans.map { |m| [m.name, m.database, m.table_name, m.source, m.error] }
      <<~SECTION.chomp
        ## Models Without a Database Table

        These models point at a table that was not found in their database.
        The table may not be migrated yet, or the model may be unused.

        #{self.class.markdown_table(%w[Model Database Table Source Error], rows)}
      SECTION
    end

    def data_element_index
      entries = @app.databases.flat_map do |db|
        db.tables.flat_map { |t| t.columns.map { |c| [c, db.name, t.name] } }
      end
      return nil if entries.empty?

      entries.sort_by! { |c, db_name, table_name| [c.name, db_name, table_name] }
      described = entries.any? { |c, _, _| c.comment }
      headers = ['Data Element Name', 'Table', 'Type', 'Null']
      headers.insert(1, 'Database') if @multi
      headers << 'Description' if described
      rows = entries.map do |c, db_name, table_name|
        row = [c.name, page_link(db_name, table_name), c.sql_type, c.null ? 'YES' : 'NO']
        row.insert(1, db_name) if @multi
        row << c.comment if described
        row
      end

      <<~SECTION.chomp
        ## Data Element Index

        Every column in alphabetic order. The same data element name may
        be used in more than one table; compare the types to spot drift.
        Each table name links to that table's page.

        #{self.class.markdown_table(headers, rows)}
      SECTION
    end
  end
end
