# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'pgdd'

require 'minitest/autorun'
require 'tmpdir'

# A small schema shared by the tests: users <- posts, with comments hanging
# off posts through a polymorphic `commentable`. No database is involved.
module Fixtures
  def users_table
    Pgdd::Table.new(
      name: 'users', comment: 'People who sign in', primary_key: 'id',
      columns: [
        Pgdd::Column.new(name: 'id', sql_type: 'uuid', null: false),
        Pgdd::Column.new(name: 'email', sql_type: 'character varying', null: false, comment: 'Unique sign-in address'),
        Pgdd::Column.new(name: 'created_at', sql_type: 'timestamp(6) without time zone', null: false)
      ],
      indexes: [Pgdd::Index.new(name: 'index_users_on_email', columns: ['email'], unique: true)],
      rows: 1234, rows_estimated: true, bytes: 65_536
    )
  end

  def posts_table
    Pgdd::Table.new(
      name: 'posts', primary_key: 'id',
      columns: [
        Pgdd::Column.new(name: 'id', sql_type: 'uuid', null: false),
        Pgdd::Column.new(name: 'user_id', sql_type: 'uuid', null: false),
        Pgdd::Column.new(name: 'title', sql_type: 'character varying', null: true, default: "'Untitled'"),
        Pgdd::Column.new(name: 'body', sql_type: 'text', null: true)
      ],
      indexes: [Pgdd::Index.new(name: 'index_posts_on_user_id', columns: ['user_id'])],
      foreign_keys: [Pgdd::ForeignKey.new(name: 'fk_posts_users', column: 'user_id', to_table: 'users', primary_key: 'id')],
      check_constraints: [Pgdd::Constraint.new(name: 'chk_title_length', expression: 'length(title) > 0')]
    )
  end

  def comments_table
    Pgdd::Table.new(
      name: 'comments', primary_key: 'id',
      columns: [
        Pgdd::Column.new(name: 'id', sql_type: 'uuid', null: false),
        Pgdd::Column.new(name: 'commentable_id', sql_type: 'uuid', null: false),
        Pgdd::Column.new(name: 'commentable_type', sql_type: 'character varying', null: false),
        Pgdd::Column.new(name: 'body', sql_type: 'text', null: false)
      ]
    )
  end

  def models
    [
      Pgdd::Model.new(name: 'User', table_name: 'users', source: 'app/models/user.rb',
                      associations: [Pgdd::Association.new(macro: :has_many, name: :posts, class_name: 'Post', foreign_key: 'user_id', options: { dependent: :destroy })],
                      validations: [Pgdd::Validation.new(kind: :presence, attributes: ['email'])]),
      Pgdd::Model.new(name: 'Post', table_name: 'posts', source: 'app/models/post.rb',
                      associations: [
                        Pgdd::Association.new(macro: :belongs_to, name: :user, class_name: 'User', foreign_key: 'user_id'),
                        Pgdd::Association.new(macro: :has_many, name: :comments, class_name: 'Comment', foreign_key: 'commentable_id', options: { as: :commentable })
                      ],
                      enums: { 'status' => { 'draft' => 0, 'published' => 1 } }),
      Pgdd::Model.new(name: 'Comment', table_name: 'comments', source: 'app/models/comment.rb',
                      associations: [Pgdd::Association.new(macro: :belongs_to, name: :commentable, class_name: nil, foreign_key: 'commentable_id', options: { polymorphic: true })])
    ]
  end

  def migrations(root = '/app')
    [
      Pgdd::Migration.new(version: '20260101120000', name: 'create_users', path: "#{root}/db/migrate/20260101120000_create_users.rb",
                          tables: { 'users' => ['create_table', 'add_index email'] }),
      Pgdd::Migration.new(version: '20260102120000', name: 'create_articles', path: "#{root}/db/migrate/20260102120000_create_articles.rb",
                          tables: { 'articles' => ['create_table'] }),
      Pgdd::Migration.new(version: '20260103120000', name: 'rename_articles_to_posts', path: "#{root}/db/migrate/20260103120000_rename_articles_to_posts.rb",
                          tables: { 'articles' => ['rename_table to posts'], 'posts' => ['rename_table from articles'] },
                          renames: [%w[articles posts]])
    ]
  end

  def database(name: 'primary', root: '/app')
    Pgdd::Database.new(name: name, adapter: 'PostgreSQL', location: 'app_development', server_version: '16.1',
                       schema_version: '20260103120000', extensions: ['plpgsql'],
                       enums: { 'post_status' => %w[draft published] },
                       tables: [comments_table, posts_table, users_table], migrations: migrations(root))
  end

  def app(databases: [database], root: '/app')
    Pgdd::App.new(name: 'Blog', root: root, environment: 'development', rails_version: '8.0.0',
                  ruby_version: '3.3.0', databases: databases, models: models)
  end
end
