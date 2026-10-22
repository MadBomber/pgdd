# frozen_string_literal: true

module Pgdd
  # Builds Graphviz ERDs from a Database: one per table (the table in full,
  # its parents and children by key columns) plus one for the whole schema.
  # Dark theme on a transparent background; boxes and edges link to the
  # table pages when name_for is given.
  class ErdWriter
    FORMATS = %w[svg dot png pdf].freeze

    GRAPH_ATTRS = 'rankdir=LR bgcolor="transparent" fontname="Arial" nodesep=0.3 ranksep=1.0'
    NODE_ATTRS  = 'shape=plaintext fontname="Arial" fontsize=12 fontcolor="#e6e6e6"'
    EDGE_ATTRS  = 'fontname="Arial" fontsize=9 color="#7aa2f7" fontcolor="#9aa4b2"'
    BORDER      = '#c8d1dc'
    TITLE_BG    = '#2b3a55'
    TYPE_COLOR  = '#9aa4b2'

    class Error < Pgdd::Error; end

    # A link the models declare but the database cannot enforce: from_table.column
    # points at to_table's id whenever type_column names model. macro is the
    # inverse side's has_one or has_many; name is the polymorphic association.
    PolymorphicKey = Data.define(:name, :column, :type_column, :to_table, :primary_key, :model, :macro)

    class << self
      # For text inside HTML-like labels and their attributes
      def escape(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      # A double-quoted DOT attribute value
      def quote(value)
        %("#{value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub(/\s*\n\s*/, ' ')}")
      end

      # HTML-like label with a title row and one row (and port) per column,
      # or per column named in only. A url makes the whole box a link; comments
      # become hover tooltips, which Graphviz only emits for cells that carry a
      # link of their own.
      def node(table, url: nil, only: nil)
        cell_link = url ? %( href="#{escape(url)}") : ''
        columns   = only ? table.columns.select { |c| only.include?(c.name) } : table.columns
        rows      = [title_row(table, cell_link)] + columns.map { |c| column_row(c, cell_link) }
        label     = %(<<table border="0" cellborder="1" cellspacing="0" cellpadding="6" color="#{BORDER}">#{rows.join}</table>>)

        attrs = ["label=#{label}"]
        attrs << "URL=#{quote(url)}" if url
        attrs << "tooltip=#{quote(table.comment)}" if table.comment
        %("#{table.name}" [#{attrs.join(' ')}];)
      end

      def title_row(table, cell_link)
        %(<tr><td bgcolor="#{TITLE_BG}"#{cell_link}><font point-size="16" color="#ffffff"><b>#{escape(table.name)}</b></font></td></tr>)
      end

      # One row per column, with a port for edges and the comment as a tooltip
      def column_row(column, cell_link)
        tooltip = column.comment ? %( title="#{escape(column.comment)}") : ''
        %(<tr><td port="#{escape(column.name)}" align="left"#{cell_link}#{tooltip}>#{escape(column.name)} ) +
          %(<font color="#{TYPE_COLOR}">[#{escape(column.sql_type)}]</font></td></tr>)
      end

      # Crow's foot on the child column, bar and ring on the parent key; a
      # PolymorphicKey is dashed, with a single tee when its inverse is has_one
      def edge(from_table, fk, url: nil)
        column = Array(fk.column).first
        key    = Array(fk.primary_key).first || 'id'
        attrs  = ['arrowhead=teeodot', 'dir=both', "label=#{quote(column)}"]
        attrs.concat(edge_attrs(fk, "#{from_table}.#{column} references #{fk.to_table}.#{key}"))
        attrs << "URL=#{quote(url)}" if url
        %("#{from_table}":"#{column}":e -> "#{fk.to_table}":"#{key}":w [#{attrs.join(' ')}];)
      end

      # Tail, style and tooltip: a solid crow's foot for a foreign key; dashed,
      # with a single tee when the inverse is has_one, for a polymorphic key
      def edge_attrs(fk, reference)
        return ['arrowtail=crow', "tooltip=#{quote(reference)}"] unless fk.is_a?(PolymorphicKey)

        [fk.macro == :has_one ? 'arrowtail=tee' : 'arrowtail=crow', 'style=dashed',
         "tooltip=#{quote("#{reference} when #{fk.type_column} is #{fk.model} (polymorphic #{fk.name})")}"]
      end

      # nodes and edges are DOT statements from .node and .edge
      def graph(name, nodes, edges)
        lines = ["digraph \"#{name}\" {",
                 "  graph [#{GRAPH_ATTRS}];",
                 "  node  [#{NODE_ATTRS}];",
                 "  edge  [#{EDGE_ATTRS}];"]
        lines.concat(nodes.map { |n| "  #{n}" })
        lines.concat(edges.map { |e| "  #{e}" })
        (lines << '}').join("\n") + "\n"
      end

      # Renders DOT source to path with Graphviz
      def render(source, path, format)
        IO.popen(['dot', "-T#{format}", '-o', path], 'w') { |dot| dot.write(source) }
        raise Error, "dot exited with #{Process.last_status.exitstatus} rendering #{path}" unless Process.last_status.success?
      end
    end

    # models are the Models backed by this database; their has_one/has_many
    # ... as: declarations become dashed PolymorphicKey edges. name_for maps a
    # table name to the file stem its page and diagram share; when given, boxes
    # and edges link to "<stem>.md"
    def initialize(db, models: [], name_for: nil)
      @db          = db
      @tables      = db.tables.to_h { |t| [t.name, t] }
      @name_for    = name_for
      @polymorphic = polymorphic_keys(models)
    end

    # [[from_table, PolymorphicKey], ...] for every `has_one/has_many ..., as:`
    # whose owner and target tables are both in this database. The association's
    # class_name is the model holding the foreign key; the declaring model is
    # the target the type column names.
    def polymorphic_keys(models)
      by_name = models.to_h { |m| [m.name, m] }
      keys = models.flat_map do |target|
        target.associations.filter_map { |a| polymorphic_key(target, a, by_name[a.class_name]) }
      end
      keys.uniq { |from, pk| [from, pk.column, pk.to_table] }
    end

    # [owner_table, PolymorphicKey] for one `has_one/has_many ..., as:` that
    # target declares and owner holds the foreign key for; nil otherwise
    def polymorphic_key(target, association, owner)
      as = association.options[:as]
      return nil unless as && association.foreign_key && %i[has_one has_many].include?(association.macro)
      return nil unless owner && @tables[owner.table_name.to_s] && @tables[target.table_name.to_s]

      [owner.table_name.to_s,
       PolymorphicKey.new(name: as.to_s, column: association.foreign_key.to_s, type_column: "#{as}_type",
                          to_table: target.table_name.to_s, primary_key: 'id',
                          model: target.name, macro: association.macro)]
    end

    def stem(name)
      @name_for ? @name_for.call(name) : name
    end

    def page_url(table_name)
      "#{@name_for.call(table_name)}.md" if @name_for
    end

    def node(table, only: nil) = self.class.node(table, url: page_url(table.name), only: only)
    def edge(from_table, fk) = self.class.edge(from_table, fk, url: page_url(from_table))

    # The primary key plus every column that the given [[table_name, ForeignKey], ...]
    # relations use on this table: enough to draw its edges without the full box
    def key_columns(table, relations)
      keys = Array(table.primary_key).map(&:to_s)
      keys = ['id'] if keys.empty?
      relations.each do |from, fk|
        if from == table.name
          keys.concat(Array(fk.column).map(&:to_s))
          keys << fk.type_column if fk.is_a?(PolymorphicKey)
        end
        keys.concat(Array(fk.primary_key).map(&:to_s)) if fk.to_table == table.name
      end
      keys.uniq
    end

    # [[table_name, ForeignKey or PolymorphicKey], ...] for keys from and to this table
    def relations(table)
      parents  = table.foreign_keys.map { |fk| [table.name, fk] }
      children = @db.tables.flat_map do |other|
        other.foreign_keys.select { |fk| fk.to_table == table.name }.map { |fk| [other.name, fk] }
      end
      poly = @polymorphic.select { |from, pk| from == table.name || pk.to_table == table.name }
      (parents + children + poly).uniq
    end

    # The table in full; its parents and children collapsed to their key columns
    def table_dot(table)
      edges = relations(table)
      names = ([table.name] + edges.flat_map { |from, fk| [from, fk.to_table] }).uniq
      nodes = names.filter_map { |n| @tables[n] }.map do |t|
        t == table ? node(t) : node(t, only: key_columns(t, edges))
      end
      self.class.graph(table.name, nodes, edges.map { |from, fk| edge(from, fk) })
    end

    # Every table collapsed to its key columns
    def schema_dot
      edges = @db.tables.flat_map { |t| t.foreign_keys.map { |fk| [t.name, fk] } } + @polymorphic
      nodes = @db.tables.map { |t| node(t, only: key_columns(t, edges)) }
      self.class.graph('schema', nodes, edges.map { |from, fk| edge(from, fk) })
    end

    # { file stem => dot source } for every diagram
    def diagrams
      @db.tables.to_h { |t| [stem(t.name), table_dot(t)] }.merge(stem('schema') => schema_dot)
    end

    # Writes STEM.FORMAT for each diagram, through Graphviz unless FORMAT is dot
    def write(dir, format: 'svg')
      FileUtils.mkdir_p(dir)
      diagrams.map do |name, source|
        path = File.join(dir, "#{name}.#{format}")
        format == 'dot' ? File.write(path, source) : self.class.render(source, path, format)
        path
      end
    end
  end
end
