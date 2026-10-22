# <%= app.name %> Database Documentation

**Start with [<%= index %>](<%= index %>).** It is the primary file in this directory: it describes each database the application uses, lists every table with a link to that table's own page, and ends with the enum types and a data element index of every column.

## As built, not as designed

This documentation is **as built**. It is generated automatically, not written by hand, from two sources:

- the schema of the database in the <%= app.environment %> environment, as it exists after every migration has run: tables, columns, types, indexes, foreign keys, constraints, triggers and enum types;
- the ActiveRecord model definitions in the codebase: associations, enums, validations, STI hierarchies and delegated types.

It therefore records what the application actually has, not what any design document says it should have. Where the two disagree, this directory is the one that is right about the current state, and the design document is the one that needs a conversation. The generation date and the schema version are recorded at the top of [<%= index %>](<%= index %>), and a warning appears there if the database had pending migrations when the report was generated.

Do not edit these files by hand; regenerate them instead (see below). This README is generated too.

## What is in this directory

<%= files_table %>
<%- if multi -%>

There is more than one database, so page and diagram names are prefixed with the database name: `queue.jobs.md`.
<%- end -%>
<%- if erd_format -%>

## Reading the diagrams

Each table's page <%= image ? 'embeds' : 'has' %> a diagram of the table and the tables it is related to.

**The table the page is about is drawn in full, with every column. The related tables are not.** A related table shows only its primary key and the columns that take part in the relationship being drawn, such as the foreign key column that points at the table in focus. This keeps a diagram readable: a table with a dozen children would otherwise stack a dozen full column lists on top of each other, and the picture becomes several screens tall.

**The full schema of any table is one click away.** Every table name in a diagram is a link to that table's own markdown page, where all of its columns, indexes and constraints are listed. Column cells are links too.

`<%= schema_stem %>.<%= erd_format %>` draws every table the same compact way, keys only, so that the shape of the whole database fits on one page.

### Notation

- An edge runs from the foreign key column of the child table to the primary key of the parent. The crow's foot marks the many side; the bar and ring mark the one, optional parent.
- **Solid edges** are foreign keys that exist in the database.
- **Dashed edges** are polymorphic associations declared in the models (`has_one`/`has_many ..., as:`), which Rails cannot back with a database foreign key. The related table shows the `_id` and `_type` column pair for these. A single bar instead of a crow's foot on the child end means the inverse is `has_one`.
- Hovering over a table, a column or an edge shows its comment, where one exists, and for a dashed edge the model the type column must name.

### Links inside the diagrams

The table names and columns in each diagram are hyperlinks to the table pages, but **they do not work on GitHub**. GitHub shows an SVG as a static image, both when it is embedded in a page and when the file itself is viewed, and clicking an image on GitHub opens the image file. The same is true of most Markdown renderers. The links only work when the diagram is opened on its own in a browser from a checkout of the repository, where the pages sit next to it.

For navigation that works everywhere, every page's Relations section starts with a list of the tables it references and the tables that reference it, each one a link, including the polymorphic associations. The Foreign Keys and Referenced By tables further down link to the related tables as well.
<%- end -%>

## Migrations

Each table page lists every migration that changed the table, oldest first, with a link to the file and a summary of what it did to this table (`create_table`, `add_column availability`, `ALTER TABLE (SQL)`, and so on). The list is built by reading the migration files, not by replaying them, so it covers the schema DSL calls, the SQL inside `execute`, and backfills that go through a model with an explicit table name. A migration that touches a table only through application models it does not name will not appear. Only the forward direction is read; `down` methods are ignored.

## Regenerating

The files are produced by the `pgdd` gem, which boots the application, reads the database and the models, and writes the pages<%= ' and diagrams' if erd_format %> into this directory.<%= ' The diagrams are rendered with Graphviz, so `dot` has to be on the `PATH`.' if erd_format && erd_format != 'dot' %> This copy was generated on <%= date %> with:

```bash
<%= command %>
```

Run it after any migration that changes the schema and commit the result together with the migration.
