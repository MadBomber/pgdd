# frozen_string_literal: true

module Pgdd
  # Reads migration files and works out which tables each one changes, from
  # the schema DSL calls and from the SQL in execute strings and heredocs.
  # Only the forward direction counts: `def down` and `dir.down` are skipped.
  class MigrationScanner
    TABLE_OPS = %w[create_table drop_table change_table add_column remove_column change_column
                   change_column_null change_column_default change_column_comment rename_column
                   add_index remove_index add_reference remove_reference add_belongs_to
                   remove_belongs_to add_check_constraint remove_check_constraint
                   add_unique_constraint remove_unique_constraint add_exclusion_constraint
                   remove_exclusion_constraint add_timestamps remove_timestamps
                   change_table_comment validate_foreign_key validate_check_constraint
                   validate_constraint].freeze

    # op :table[, :column | %i[a b] | [:a, :b] | "string"]
    ARGUMENT    = /(?:\s*,\s*(?::(\w+)|%i\[([^\]]*)\]|\[([^\]]*)\]|"([^"]*)"|'([^']*)'))?/
    # longest names first so change_column_null is not read as change_column
    OPS         = TABLE_OPS.sort_by { |op| -op.size }.join('|')
    DSL_CALL    = /\b(#{OPS})\b\s*\(?\s*:(\w+)#{ARGUMENT}/
    # The same call with a variable for the table, as in `TABLES.each { |t| add_column t, ... }`;
    # the change is attributed to every word in the file's %i[...] and %w[...] literals
    DSL_VAR     = /\b(#{OPS})\b\s*\(?\s*([a-z_]\w*)#{ARGUMENT}/
    WORD_LISTS  = /%[iw]\[([^\]]*)\]/m
    RENAME      = /\brename_table\s*\(?\s*:(\w+)\s*,\s*:(\w+)/
    JOIN_TABLE  = /\bcreate_join_table\s*\(?\s*:(\w+)\s*,\s*:(\w+)/
    FOREIGN_KEY = /\b(add|remove)_foreign_key\s*\(?\s*:(\w+)\s*,\s*:(\w+)/
    MODEL_TABLE = /self\.table_name\s*=\s*['"](\w+)['"]/
    SQL         = /\b(?<verb>ALTER\s+TABLE|CREATE\s+TABLE|DROP\s+TABLE|TRUNCATE\s+TABLE|CREATE\s+(?:UNIQUE\s+)?INDEX\s+\S+\s+ON|UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?(?:ONLY\s+)?"?(?<table>\w+)"?/i
    HEREDOC     = /<<[~-]?(['"]?)([A-Z_]+)\1[^\n]*\n(.*?)^\s*\2\s*$/m
    EXEC_STRING = /\bexecute\s*\(?\s*(['"])(.*?)\1/m
    FILENAME    = /\A(\d+)_(.+)\.rb\z/

    class << self
      # The source with comment lines, `def down ... end`, `dir.down do ... end`
      # and one-line `dir.down { ... }` removed. A block ends at the first line
      # whose indentation matches the line that opened it.
      def forward_source(source)
        skip = nil
        source.lines.filter_map do |line|
          if skip
            skip = nil if line.match?(/\A#{skip}end\b/)
            next
          end
          next if line.match?(/\A\s*#/) || line.match?(/\bdir\.down\s*\{/)

          if (m = line.match(/\A(\s*)(?:def down\b|dir\.down\s+do\b)/))
            skip = m[1]
            next
          end
          line
        end.join
      end

      # SQL fragments in execute strings and heredocs
      def sql_blocks(source)
        source.scan(HEREDOC).map(&:last) + source.scan(EXEC_STRING).map(&:last)
      end

      # The ARGUMENT captures rendered as "col" or "[a, b]": one of a :symbol,
      # a %i[...] list, a [...] list, a "string" or a 'string'
      def argument(symbol, words, list, double_quoted, single_quoted)
        return symbol if symbol
        return "[#{words.split.join(', ')}]" if words
        return "[#{list.delete(':').split(/\s*,\s*/).join(', ')}]" if list

        double_quoted || single_quoted
      end

      def change(op, *argument_captures)
        [op, argument(*argument_captures)].compact.join(' ')
      end

      # { table => [change, ...] } in file order, from the forward source
      def tables(source)
        src    = forward_source(source)
        tables = Hash.new { |h, k| h[k] = [] }
        dsl_changes(src, tables)
        looped_changes(src, tables)
        structural_changes(src, tables)
        sql_changes(src, tables)
        tables.transform_values(&:uniq)
      end

      # `op :table, ...` calls
      def dsl_changes(src, tables)
        src.scan(DSL_CALL) { |op, table, *args| tables[table] << change(op, *args) }
      end

      # `op variable, ...` calls, attributed to every word list in the file
      def looped_changes(src, tables)
        looped = src.scan(WORD_LISTS).flatten.flat_map(&:split).uniq
        src.scan(DSL_VAR) do |op, _variable, *args|
          described = change(op, *args)
          looped.each { |table| tables[table] << described }
        end
      end

      # Renames, join tables, foreign keys and data changes through a model
      def structural_changes(src, tables)
        src.scan(RENAME) do |old_name, new_name|
          tables[old_name] << "rename_table to #{new_name}"
          tables[new_name] << "rename_table from #{old_name}"
        end
        src.scan(JOIN_TABLE) { |left, right| tables[[left, right].sort.join('_')] << 'create_join_table' }
        src.scan(FOREIGN_KEY) do |verb, from, to|
          tables[from] << "#{verb}_foreign_key to #{to}"
          tables[to] << "#{verb}_foreign_key from #{from}"
        end
        src.scan(MODEL_TABLE) { |(table)| tables[table] << 'data change through a model' }
      end

      # Statements inside execute strings and heredocs
      def sql_changes(src, tables)
        sql_blocks(src).each do |sql|
          sql.scan(SQL) { |verb, table| tables[table] << "#{sql_verb(verb)} (SQL)" }
        end
      end

      def sql_verb(verb)
        verb.upcase.gsub(/\s+/, ' ').sub(/ (UNIQUE )?INDEX .*/, ' INDEX')
      end

      def renames(source)
        forward_source(source).scan(RENAME)
      end

      def migration(path)
        version, name = File.basename(path).match(FILENAME)&.captures
        source = File.read(path)
        Migration.new(version: version || '0', name: name || File.basename(path, '.rb'), path: path,
                      tables: tables(source), renames: renames(source))
      end
    end

    # paths are migration directories, absolute or relative to root
    def initialize(paths, root: Dir.pwd)
      @dirs = Array(paths).map { |path| File.expand_path(path.to_s, root) }
    end

    # [Migration, ...] oldest first; missing directories are skipped
    def call
      @dirs.flat_map { |dir| Dir[File.join(dir, '*.rb')] }.sort.map { |path| self.class.migration(path) }
    end
  end
end
