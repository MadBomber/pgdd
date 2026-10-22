# frozen_string_literal: true

require 'test_helper'

class MigrationScannerTest < Minitest::Test
  Scanner = Pgdd::MigrationScanner

  def test_create_table_with_indexes
    source = <<~RUBY
      class CreateUsers < ActiveRecord::Migration[8.0]
        def change
          create_table :users, id: :uuid do |t|
            t.string :email, null: false
            t.timestamps
          end
          add_index :users, :email, unique: true
          add_index :users, %i[last_name first_name]
          add_index :users, [:tenant_id, :slug], unique: true
        end
      end
    RUBY

    assert_equal({ 'users' => ['create_table', 'add_index email', 'add_index [last_name, first_name]', 'add_index [tenant_id, slug]'] },
                 Scanner.tables(source))
  end

  def test_longer_operation_names_win
    source = "change_column_null :posts, :title, false\nchange_column_default :posts, :title, from: nil, to: 'x'\n"

    assert_equal({ 'posts' => ['change_column_null title', 'change_column_default title'] }, Scanner.tables(source))
  end

  def test_down_method_and_dir_down_are_skipped
    source = <<~RUBY
      def up
        add_column :posts, :views, :integer
        reversible do |dir|
          dir.up do
            execute "UPDATE posts SET views = 0"
          end
          dir.down do
            execute "UPDATE posts SET views = NULL"
          end
        end
        dir.down { remove_column :posts, :views }
      end

      def down
        remove_column :posts, :views
        drop_table :archives
      end
    RUBY

    tables = Scanner.tables(source)

    assert_equal ['add_column views', 'UPDATE (SQL)'], tables['posts']
    refute_includes tables.keys, 'archives'
  end

  def test_comment_lines_are_ignored
    source = "# add_column :posts, :ghost, :string\nadd_column :posts, :real, :string\n"

    assert_equal({ 'posts' => ['add_column real'] }, Scanner.tables(source))
  end

  def test_sql_in_heredocs_with_method_calls_on_the_delimiter
    source = <<~RUBY
      execute(<<~SQL.squish)
        UPDATE sites SET code = external_id WHERE code IS NULL
      SQL
      execute <<-SQL
        ALTER TABLE integration_connections ALTER COLUMN status TYPE text;
        CREATE UNIQUE INDEX idx_slug ON "sites" (slug);
        INSERT INTO audits (id) VALUES (1);
        DELETE FROM stale_rows WHERE 1 = 1;
      SQL
    RUBY

    tables = Scanner.tables(source)

    assert_equal ['UPDATE (SQL)', 'CREATE INDEX (SQL)'], tables['sites']
    assert_equal ['ALTER TABLE (SQL)'], tables['integration_connections']
    assert_equal ['INSERT INTO (SQL)'], tables['audits']
    assert_equal ['DELETE FROM (SQL)'], tables['stale_rows']
  end

  def test_sql_in_execute_strings
    assert_equal({ 'posts' => ['ALTER TABLE (SQL)'] },
                 Scanner.tables(%(execute "ALTER TABLE posts ADD COLUMN x int")))
  end

  def test_sql_outside_execute_is_not_scanned
    assert_empty Scanner.tables("# nothing\nnotes = 'UPDATE posts SET x = 1'\n")
  end

  def test_loop_variables_attribute_to_every_listed_table
    source = <<~RUBY
      TABLES = %i[
        artifacts
        encounters
      ].freeze

      def change
        TABLES.each do |table|
          change_column_null table, :study_id, false
        end
        %w[sites studies].each { |t| add_column t, :slug, :string }
      end
    RUBY

    tables = Scanner.tables(source)

    %w[artifacts encounters sites studies].each do |name|
      assert_equal ['change_column_null study_id', 'add_column slug'], tables[name], name
    end
  end

  def test_rename_join_and_foreign_key_calls
    source = <<~RUBY
      rename_table :articles, :posts
      create_join_table :tags, :posts
      add_foreign_key :posts, :users, column: :author_id
      remove_foreign_key :comments, :posts
    RUBY

    tables = Scanner.tables(source)

    assert_equal ['rename_table to posts'], tables['articles']
    assert_equal ['rename_table from articles', 'add_foreign_key to users', 'remove_foreign_key from comments'], tables['posts']
    assert_equal ['create_join_table'], tables['posts_tags']
    assert_equal ['add_foreign_key from posts'], tables['users']
    assert_equal [%w[articles posts]], Scanner.renames(source)
  end

  def test_model_backfill_with_explicit_table_name
    source = <<~RUBY
      class MigrationUser < ActiveRecord::Base
        self.table_name = 'users'
      end

      def up
        MigrationUser.find_each { |u| u.update!(slug: u.email) }
      end
    RUBY

    assert_equal({ 'users' => ['data change through a model'] }, Scanner.tables(source))
  end

  def test_string_arguments_are_kept
    assert_equal({ 'tubes' => ['add_check_constraint volume_ul > 0'] },
                 Scanner.tables(%(add_check_constraint :tubes, "volume_ul > 0", name: "chk")))
  end

  def test_scans_a_directory_in_version_order
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '20260102000000_add_title.rb'), "add_column :posts, :title, :string\n")
      File.write(File.join(dir, '20260101000000_create_posts.rb'), "create_table :posts\n")
      File.write(File.join(dir, 'README.md'), 'not a migration')

      migrations = Scanner.new([dir, File.join(dir, 'missing')]).call

      assert_equal %w[create_posts add_title], migrations.map(&:name)
      assert_equal %w[20260101000000 20260102000000], migrations.map(&:version)
      assert_equal({ 'posts' => ['create_table'] }, migrations.first.tables)
      assert_equal File.join(dir, '20260101000000_create_posts.rb'), migrations.first.path
    end
  end

  def test_relative_paths_resolve_against_root
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'db/migrate'))
      File.write(File.join(dir, 'db/migrate/1_x.rb'), "drop_table :old\n")

      migrations = Scanner.new(['db/migrate'], root: dir).call

      assert_equal 1, migrations.size
      assert_equal '1', migrations.first.version
      assert_equal 'x', migrations.first.name
    end
  end

  def test_file_without_a_version_prefix
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'odd.rb'), "drop_table :old\n")

      migration = Scanner.migration(File.join(dir, 'odd.rb'))

      assert_equal '0', migration.version
      assert_equal 'odd', migration.name
    end
  end
end
