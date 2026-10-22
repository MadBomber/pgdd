## [Unreleased]

## [0.1.0] - 2026-10-22

Initial release, converted from the single-file `data_dictionary_v3.rb` script.

- `pgdd` command and `pgdd:generate` rake task.
- A generated `README.md` in the output directory, from `lib/pgdd/readme_template.md`: what the files are, how to read the diagrams, and the command that produced the copy.
- Markdown index page and one page per table: columns, indexes, foreign keys, referencing tables, check constraints, triggers, migrations and model details.
- Graphviz ERD per table (focus table in full, related tables by key columns) and one for the whole schema; dark theme, transparent background, boxes and edges link to the pages.
- Polymorphic associations drawn as dashed edges from the models' `has_one`/`has_many ..., as:` declarations.
- Migrations that changed each table, found by reading `db/migrate`: schema DSL calls, SQL in `execute`, model backfills with an explicit table name, and renames.
- Several databases (`--database`, `--all-databases`), SQLite and PostgreSQL specifics, exact or estimated row counts.
