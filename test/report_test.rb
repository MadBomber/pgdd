# frozen_string_literal: true

require 'test_helper'

class ReportTest < Minitest::Test
  include Fixtures

  Report = Pgdd::Report

  def report(erd_format: 'svg', output_dir: '/app/docs/database', **app_options)
    Report.new(app(**app_options), date: Date.new(2026, 10, 22), erd_format: erd_format, output_dir: output_dir)
  end

  def test_markdown_table_aligns_the_pipes
    table = Report.markdown_table(%w[Name Value], [['a', 'long value'], ['bb', 'x|y']])

    assert_equal <<~MD.chomp, table
      | Name | Value      |
      | ---- | ---------- |
      | a    | long value |
      | bb   | x\\|y       |
    MD
  end

  def test_formatting_helpers
    assert_equal '2026-10-19 16:27:07 (20261019162707)', Report.format_version('2026_10_19_162707')
    assert_equal 'unknown', Report.format_version(nil)
    assert_equal '42', Report.format_version(42)
    assert_equal '1,234,567', Report.number(1_234_567)
    assert_equal '-12', Report.number(-12)
    assert_equal '512 B', Report.human_size(512)
    assert_equal '64.0 KB', Report.human_size(65_536)
    assert_equal '1.5 GB', Report.human_size(1.5 * (1024**3))
    assert_equal '', Report.human_size(nil)
    assert_equal 'a: 1, b: x, y, c: (proc), d: {e: :f}', Report.format_options(a: 1, b: %w[x y], c: -> {}, d: { e: :f })
    assert_equal 'draft (0), published (1)', Report.enum_values('draft' => 0, 'published' => 1)
    assert_equal 'red, blue', Report.enum_values('red' => 'red', 'blue' => 'blue')
    assert_equal '~1,234', Report.rows_label(users_table)
  end

  def test_pages_has_the_index_and_one_page_per_table
    assert_equal %w[README.md INDEX.md comments.md posts.md users.md], report.pages.keys
  end

  def test_readme_describes_the_directory_and_how_it_was_made
    md = Report.new(app, date: Date.new(2026, 10, 22), erd_format: 'svg', command: 'pgdd -d primary -o docs/db').pages['README.md']

    assert_includes md, '# Blog Database Documentation'
    assert_includes md, '**Start with [INDEX.md](INDEX.md).**'
    assert_includes md, 'the database in the development environment'
    assert_includes md, '| `<table>.md`  | One page per table:'
    assert_includes md, '| `<table>.svg` | The entity relationship diagram for that table, embedded in its page.'
    assert_includes md, '| `schema.svg`  | One diagram of every table in the database.'
    assert_includes md, '## Reading the diagrams'
    assert_includes md, 'they do not work on GitHub'
    assert_includes md, '## Migrations'
    assert_includes md, "generated on 2026-10-22 with:\n\n```bash\npgdd -d primary -o docs/db\n```"
    assert_includes md, 'rendered with Graphviz'
    refute_includes md, 'more than one database'
  end

  def test_readme_without_diagrams
    md = report(erd_format: nil).pages['README.md']

    refute_includes md, '## Reading the diagrams'
    refute_includes md, '.svg'
    refute_includes md, 'Graphviz'
    assert_includes md, 'writes the pages into this directory.'
  end

  def test_readme_with_dot_source_and_several_databases
    r  = report(erd_format: 'dot', databases: [database, Pgdd::Database.new(name: 'queue', tables: [users_table])])
    md = r.pages['README.md']

    assert_includes md, '| `<database>.<table>.dot` | The entity relationship diagram for that table.'
    assert_includes md, '| `<database>.schema.dot`  | One diagram of every table in the database.'
    assert_includes md, 'more than one database'
    assert_includes md, "Each table's page has a diagram"
    refute_includes md, 'Graphviz'
  end

  def test_index_lists_databases_tables_enums_and_every_column
    md = report.index_markdown

    assert_includes md, '# Blog Database Documentation'
    assert_includes md, 'generated on 2026-10-22'
    assert_includes md, '| primary  | PostgreSQL | 16.1'
    assert_includes md, '[posts](posts.md)'
    assert_includes md, '**Extensions:** plpgsql'
    assert_includes md, '| post_status | draft, published |'
    assert_includes md, '## Data Element Index'
    assert_includes md, '| commentable_type  | [comments](comments.md)'
    assert_includes md, '| Description'
    refute_includes md, 'Models Without a Database Table'
  end

  def test_index_warns_about_unreadable_databases_and_pending_migrations
    broken  = Pgdd::Database.new(name: 'queue', error: 'PG::ConnectionBad: refused')
    pending = Pgdd::Database.new(name: 'primary', tables: [users_table], pending_migrations: true)
    md = report(databases: [pending, broken]).index_markdown

    assert_includes md, '> **queue:** could not be read: PG::ConnectionBad: refused'
    assert_includes md, '> **primary:** has pending migrations'
    assert_includes md, '## primary Database Tables'
  end

  def test_orphan_models_are_listed
    db = Pgdd::Database.new(name: 'primary', tables: [users_table])
    md = report(databases: [db]).index_markdown

    assert_includes md, '## Models Without a Database Table'
    assert_includes md, '| Post    | primary  | posts    | app/models/post.rb    |'
    assert_includes md, '| Comment | primary  | comments |'
  end

  def test_table_page_relations_list_links_both_directions
    md = report.pages['posts.md']

    assert_includes md, "**References:**\n\n- [users](users.md) via `user_id`"
    assert_includes md, "**Referenced by:**\n\n- [comments](comments.md) via `commentable_id` (polymorphic)"
    assert_includes md, '![posts entity relationship diagram](posts.svg)'
    assert_includes md, 'dashed edges are polymorphic'
  end

  def test_table_page_without_relations_or_diagram
    db = Pgdd::Database.new(name: 'primary', tables: [users_table])
    md = report(databases: [db], erd_format: nil).pages['users.md']

    assert_includes md, 'No other table is related to this one.'
    refute_includes md, '.svg'
  end

  def test_table_page_schema_sections
    md = report.pages['posts.md']

    assert_includes md, '**Kind:** table · **Primary key:** id'
    assert_includes md, "| user_id | uuid              | NO   |            | FK → users |"
    assert_includes md, "| title   | character varying | YES  | 'Untitled' |            |"
    assert_includes md, '| index_posts_on_user_id | user_id |'
    assert_includes md, '| user_id | [users](users.md).id |'
    assert_includes md, '| chk_title_length | `length(title) > 0` |'
    assert_includes md, '[Back to the index](INDEX.md)'
  end

  def test_users_page_shows_who_references_it_and_the_unique_key
    md = report.pages['users.md']

    assert_includes md, 'People who sign in'
    assert_includes md, '**Rows:** ~1,234 (estimate) · **Size:** 64.0 KB'
    assert_includes md, '| email      | character varying              | NO   |         | UQ  | Unique sign-in address |'
    assert_includes md, "## Referenced By\n\n| Table             | Column  |"
    assert_includes md, '| [posts](posts.md) | user_id |'
  end

  def test_migrations_section_follows_renames_and_links_relative_to_the_output_dir
    md = report.pages['posts.md']

    assert_includes md, '## Migrations'
    assert_includes md, '| 2026-01-02 12:00:00 | [create_articles](../../db/migrate/20260102120000_create_articles.rb)'
    assert_includes md, '| 2026-01-03 12:00:00 | [rename_articles_to_posts](../../db/migrate/20260103120000_rename_articles_to_posts.rb)'
    assert_includes md, '`rename_table from articles`, `rename_table to posts`'
    refute_includes md, 'create_users'
  end

  def test_migration_links_are_absolute_without_an_output_dir
    md = report(output_dir: nil).pages['users.md']

    assert_includes md, '[create_users](/app/db/migrate/20260101120000_create_users.rb)'
  end

  def test_model_sections
    md = report.pages['posts.md']

    assert_includes md, "## Model: Post\n\n**Source:** `app/models/post.rb`"
    assert_includes md, '| has_many   | comments | Comment | commentable_id | as: :commentable |'
    assert_includes md, '| belongs_to | user     | User    | user_id        |                  |'
    assert_includes md, "### Post Enums\n\n| Attribute | Values                   |\n| --------- | ------------------------ |\n| status    | draft (0), published (1) |"
    assert_includes report.pages['comments.md'], '| belongs_to | commentable | (polymorphic) |'
    assert_includes report.pages['users.md'], '| presence   | email      |'
  end

  def test_model_errors_are_reported_on_the_page
    broken = Pgdd::Model.new(name: 'User', table_name: 'users', error: 'NameError: boom')
    a  = Pgdd::App.new(name: 'Blog', root: '/app', environment: 'test', rails_version: '8', ruby_version: '3.3',
                       databases: [database], models: [broken])
    md = Report.new(a).pages['users.md']

    assert_includes md, "## Model: User\n\nCould not be inspected: NameError: boom"
  end

  def test_several_databases_prefix_the_page_names
    r = report(databases: [database, Pgdd::Database.new(name: 'queue', tables: [users_table])])

    assert_equal %w[README.md INDEX.md primary.comments.md primary.posts.md primary.users.md queue.users.md], r.pages.keys
    assert_includes r.pages['primary.posts.md'], '# primary.posts'
    assert_includes r.pages['primary.posts.md'], '[users](primary.users.md)'
    assert_includes r.index_markdown, '| Data Element Name | Database |'
  end
end
