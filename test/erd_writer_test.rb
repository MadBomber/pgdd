# frozen_string_literal: true

require 'test_helper'

class ErdWriterTest < Minitest::Test
  include Fixtures

  Writer = Pgdd::ErdWriter

  def writer(name_for: nil)
    Writer.new(database, models: models, name_for: name_for)
  end

  def test_escape_and_quote
    assert_equal '&lt;a&gt; &amp; &quot;b&quot;', Writer.escape('<a> & "b"')
    assert_equal '"say \"hi\" now"', Writer.quote("say \"hi\"\n  now")
  end

  def test_node_lists_every_column_with_ports_and_tooltips
    dot = Writer.node(users_table, url: 'users.md')

    assert_match(/\A"users" \[label=<<table/, dot)
    assert_includes dot, '<td port="email" align="left" href="users.md" title="Unique sign-in address">email'
    assert_includes dot, '<font color="#9aa4b2">[character varying]</font>'
    assert_includes dot, 'URL="users.md"'
    assert_includes dot, 'tooltip="People who sign in"'
    assert_equal 3, dot.scan('<tr><td port=').size
  end

  def test_node_only_keeps_the_named_columns
    dot = Writer.node(posts_table, only: %w[id user_id])

    assert_includes dot, 'port="id"'
    assert_includes dot, 'port="user_id"'
    refute_includes dot, 'port="title"'
    refute_includes dot, 'URL='
  end

  def test_foreign_key_edge_is_solid_with_a_crows_foot
    dot = Writer.edge('posts', posts_table.foreign_keys.first, url: 'posts.md')

    assert_match(/\A"posts":"user_id":e -> "users":"id":w \[/, dot)
    assert_includes dot, 'arrowtail=crow'
    assert_includes dot, 'tooltip="posts.user_id references users.id"'
    assert_includes dot, 'URL="posts.md"'
    refute_includes dot, 'dashed'
  end

  def test_polymorphic_edge_is_dashed_and_names_the_model
    key = writer.polymorphic_keys(models).first.last
    dot = Writer.edge('comments', key)

    assert_includes dot, 'style=dashed'
    assert_includes dot, 'arrowtail=crow'
    assert_includes dot, 'tooltip="comments.commentable_id references posts.id when commentable_type is Post (polymorphic commentable)"'
  end

  def test_has_one_inverse_gets_a_single_tee
    key = Writer::PolymorphicKey.new(name: 'detail', column: 'detail_id', type_column: 'detail_type',
                                     to_table: 'tubes', primary_key: 'id', model: 'Tube', macro: :has_one)

    assert_includes Writer.edge('artifacts', key), 'arrowtail=tee'
  end

  def test_polymorphic_keys_come_from_has_many_as_declarations
    keys = writer.polymorphic_keys(models)

    assert_equal 1, keys.size
    from, key = keys.first
    assert_equal 'comments', from
    assert_equal 'commentable_id', key.column
    assert_equal 'commentable_type', key.type_column
    assert_equal 'posts', key.to_table
    assert_equal 'Post', key.model
  end

  def test_polymorphic_keys_skip_tables_not_in_the_database
    db = Pgdd::Database.new(name: 'primary', tables: [posts_table])

    assert_empty Writer.new(db, models: models).polymorphic_keys(models)
  end

  def test_relations_cover_both_directions_and_polymorphic_links
    relations = writer.relations(posts_table)

    assert_equal([%w[posts users], %w[comments posts]], relations.map { |from, key| [from, key.to_table] })
    assert_kind_of Writer::PolymorphicKey, relations.last.last
  end

  def test_key_columns_keep_the_primary_key_and_the_linking_columns
    w = writer

    assert_equal %w[id user_id], w.key_columns(posts_table, w.relations(posts_table))
    assert_equal %w[id commentable_id commentable_type], w.key_columns(comments_table, w.relations(comments_table))
    assert_equal ['id'], w.key_columns(users_table, w.relations(users_table))
  end

  def test_key_columns_fall_back_to_id_without_a_primary_key
    table = Pgdd::Table.new(name: 'log', columns: [Pgdd::Column.new(name: 'id', sql_type: 'int')])

    assert_equal ['id'], writer.key_columns(table, [])
  end

  def test_table_dot_draws_the_focus_in_full_and_neighbours_by_keys
    dot = writer(name_for: ->(n) { n }).table_dot(posts_table)

    assert_match(/\Adigraph "posts" \{/, dot)
    assert_includes dot, 'port="body"'            # posts in full
    refute_includes dot, 'port="email"'           # users collapsed to id
    assert_includes dot, '"users" [label='
    assert_includes dot, '"comments" [label='
    assert_includes dot, 'href="users.md"'
    assert_equal 1, dot.scan('style=dashed').size
    assert_equal 2, dot.scan(' -> ').size
  end

  def test_schema_dot_collapses_every_table
    dot = writer.schema_dot

    assert_match(/\Adigraph "schema" \{/, dot)
    assert_equal 3, dot.scan(' [label=').size
    refute_includes dot, 'port="title"'
    assert_includes dot, 'port="commentable_type"'
  end

  def test_diagrams_use_the_name_for_stems
    stems = writer(name_for: ->(n) { "primary.#{n}" }).diagrams.keys

    assert_equal %w[primary.comments primary.posts primary.users primary.schema], stems
  end

  def test_write_dot_files
    Dir.mktmpdir do |dir|
      paths = writer.write(File.join(dir, 'out'), format: 'dot')

      assert_equal 4, paths.size
      assert(paths.all? { |p| File.exist?(p) })
      assert_match(/\Adigraph "users"/, File.read(File.join(dir, 'out', 'users.dot')))
    end
  end

  def test_render_raises_on_dot_failure
    skip 'needs Graphviz dot' unless system('dot', '-V', out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      capture_subprocess_io do
        assert_raises(Writer::Error) { Writer.render('this is not dot', File.join(dir, 'x.svg'), 'svg') }
      end
    end
  end
end
