# pgdd

As-built database documentation for a Rails application, with entity relationship diagrams.

`pgdd` boots your application, reads its live database and its ActiveRecord models, and writes Markdown you can commit next to the code: an index page, one page per table, and a Graphviz diagram per table plus one of the whole schema. Nothing is hand-written and nothing comes from a design document. It records what the application actually has.

From the database it reads tables, views, columns, keys, indexes, foreign keys, check constraints, triggers, comments, enum types, extensions, row counts and sizes. From the models it reads associations, enums, validations, STI hierarchies, store accessors, attachments, encrypted and virtual attributes. From `db/migrate` it works out which migrations changed each table.

PostgreSQL gets the fullest treatment (enum types, triggers, planner row estimates, materialized views). SQLite is supported, and anything else ActiveRecord can connect to gets the parts the adapter exposes.

## Installation

Add it to the application's Gemfile, in the development group:

```ruby
group :development do
  gem 'pgdd'
end
```

The diagrams are rendered with Graphviz, so `dot` must be on the `PATH` (`brew install graphviz`, `apt install graphviz`). Without it, use `--erd-format dot` to write the DOT source instead, or `--no-erd`.

Requires Ruby 3.2+ and Rails 6.1+. The gem has no runtime dependencies of its own; it runs inside the application's Rails.

## Usage

From the application's root:

```bash
bundle exec pgdd --output docs/database
```

Or as a rake task, which does the same thing inside the loaded application:

```bash
bin/rails "pgdd:generate[docs/database]"
PGDD_OPTIONS="--count --all-databases" bin/rails pgdd:generate
```

Without `--output`, only the index page is written, to STDOUT.

| Option                  | Effect                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------ |
| `-o`, `--output DIR`    | Write the index, one page per table and the diagrams to DIR                                |
| `-e`, `--environment`   | Rails environment (default: `RAILS_ENV` or `development`)                                  |
| `-d`, `--database NAME` | Report this database config; repeatable (default: the primary only)                        |
| `-a`, `--all-databases` | Report every database config (cache, queue, cable, ...)                                    |
| `-c`, `--count`         | Exact row counts with `SELECT COUNT(*)` instead of planner estimates (can be slow)          |
| `-i`, `--internal`      | Include `schema_migrations` and `ar_internal_metadata`                                     |
| `-f`, `--erd-format`    | `svg` (default), `png`, `pdf`, or `dot` for the source                                     |
| `--no-erd`              | Skip the diagrams                                                                          |

`pgdd` only reads. The whole run happens inside `ActiveRecord::Base.while_preventing_writes`.

## What it writes

| File                 | Content                                                                                                                                                        |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`          | A guide to the directory: what the files are, how to read the diagrams, and the exact command that generated this copy. Rendered from the gem's `readme_template.md` |
| `INDEX.md`           | The index: each database with its adapter, version and schema version; every table with a link to its page; enum types; models without a table; a data element index of every column across all tables |
| `<table>.md`         | Columns, indexes, foreign keys, the tables that reference it, check constraints, triggers, the migrations that changed it, and the models backed by it           |
| `<table>.svg`        | The table's entity relationship diagram, embedded in its page                                                                                                  |
| `schema.svg`         | Every table in one diagram                                                                                                                                     |

With more than one database, page and diagram names are prefixed: `queue.solid_queue_jobs.md`.

The Markdown passes markdownlint and prettier as written: table pipes are aligned, and there are no hard-wrapped tables.

### The diagrams

Each table's diagram draws that table in full. Its related tables are collapsed to their primary key and the columns that take part in the relationship, so a table with a dozen children stays readable instead of becoming several screens tall. The full schema of a related table is one click away: every table name and column in a diagram links to that table's page. `schema.svg` draws every table the compact way.

- Solid edges are foreign keys that exist in the database. Crow's foot on the many side, bar and ring on the parent key.
- Dashed edges are polymorphic associations the models declare (`has_one`/`has_many ..., as:`), which Rails cannot back with a database foreign key. A single bar on the child end means the inverse is `has_one`.
- Hovering shows table and column comments, and for a dashed edge the model the type column must name.

Dark theme, transparent background, so they look right on both GitHub themes.

**The links inside an SVG do not work on GitHub.** GitHub shows an SVG as a static image, embedded or on its own, and clicking an image opens the file. The links work when the SVG is opened from a checkout. For navigation that works everywhere, each page's Relations section opens with a linked list of the tables it references and the tables that reference it, polymorphic ones included.

### Migrations

Each page lists every migration that changed the table, oldest first, with a link to the file and what it did (`create_table`, `add_column availability`, `ALTER TABLE (SQL)`). The list comes from reading the migration files, not replaying them. It covers the schema DSL calls, including calls inside loops over a `%i[...]` list of tables, SQL inside `execute` strings and heredocs, backfills through a migration-local model with an explicit `table_name`, and `rename_table`, so a renamed table's page includes the migrations under its old name. Only the forward direction is read; `down` methods and `dir.down` blocks are ignored. A migration that changes data only through application models it does not name by table will not appear.

## Library use

The command is a thin wrapper. Inside a booted application:

```ruby
app    = Pgdd::Collector.new(root: Rails.root.to_s, count_rows: true).call   # Pgdd::App
report = Pgdd::Report.new(app, erd_format: 'svg', output_dir: 'docs/database')
report.pages                                                                 # { 'README.md' => '...', 'INDEX.md' => '...', 'users.md' => '...' }
Pgdd::ErdWriter.new(app.databases.first, models: app.models).diagrams        # { 'users' => 'digraph ...', 'schema' => '...' }
```

`Pgdd::App` and everything under it are plain `Data` values, so `Report` and `ErdWriter` need no database and are tested without one. `Pgdd::MigrationScanner.tables(source)` works on any migration source string.

## Development

```bash
bundle install
bundle exec rake test
```

The tests cover the scanner, the report and the diagram builder with hand-built values. Running the command end to end needs a Rails application; point it at one with `bundle exec bin/pgdd path/to/app --output /tmp/dd`.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
