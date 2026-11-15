# Changelog

## 0.2.0

### Breaking changes from 0.1.0

  * The Erlang driver returns text and `RAW` values as binaries (charlists
    before), numbers without the tuple around them, time zones, `INTERVAL
    YEAR TO MONTH` values and error messages as binaries. Binary binds are
    text; `RAW` binds are `{raw, Bytes}`. `Orax.Query` no longer turns lists
    into binaries, so JSON arrays come back as lists.
  * `:on_conflict` other than `:raise`, in `insert` and `insert_all` alike,
    raises an error instead of being ignored, and so does inserting a row
    without fields.

### Protocol

  * Rewrite the TTC message layer after python-oracledb thin mode: the
    capabilities and data types of python-oracledb are negotiated, with the
    TTC field version of 23.4 on 26ai and 19.1 on 19c, and each message is
    decoded by a function of its own.
  * Fetch CLOB and BLOB columns as LONG and LONG RAW, so their content comes
    with the rows.
  * Decode JSON (OSON) columns into maps and lists and BOOLEAN columns into
    `true`/`false` on 26ai.
  * Bind and fetch VECTOR values in their binary form on 26ai (dense and
    sparse, all formats), as `Orax.Vector` structs in Elixir with the
    `Orax.Ecto.Vector` Ecto type; VECTOR binds before 23.4 are an error.
  * Keep the sign of negative `INTERVAL DAY TO SECOND` values under a day.
  * Bind RAW values longer than 4000 bytes.
  * A NULL bind takes the type of the first value of the rows that is not
    NULL, as python-oracledb does.
  * The client character set defaults to AL32UTF8.
  * Send connect data longer than 230 bytes in a data packet of its own, as
    long connect descriptors (TLS) need.
  * Start `:ssl` with the application.
  * Answer a flush out binds message at once when the server marks the end
    of responses.

### Ecto adapter

  * `insert_all` of several rows runs the single-row `INSERT` as array DML
    (one round trip, 19c and 26ai, `RETURNING` for every row) instead of a
    multi-row `VALUES`, which needs 23ai; a failing row inserts none of them.
  * Batched `Repo.query/4` calls (`batch: true`) are atomic and take `:out`
    binds.
  * `type(^vector, Orax.Ecto.Vector)` leaves the bind as it is (Oracle has
    no `CAST` to VECTOR).

## 0.1.0

First release of orax, forked from
[jamdb_oracle](https://github.com/erlangbureau/jamdb_oracle) 0.5.12.

### Breaking changes from jamdb_oracle

  * The project is renamed: the Hex package and OTP application are `:orax`,
    Erlang modules `jamdb_oracle_*` are `orax_*`, `Jamdb.Oracle` is `Orax` and
    the Ecto adapter is `Ecto.Adapters.Orax`. Application config moves from
    `config :jamdb_oracle` to `config :orax`.
  * Supported servers are Oracle Database 19c and 26ai (23ai).
  * Requires Elixir 1.18, OTP 27 and ecto_sql 3.14 or later.
  * The JSON library defaults to Elixir's built-in `JSON` instead of `Jason`.
    Set `config :orax, :json_library, Jason` to keep Jason.
  * The default `app_name` sent to the server, shown as the program in
    `V$SESSION`, is `"orax"` instead of `"jamdb"`.
  * The `:read_timeout` parameter is removed. Responses are read until the
    protocol marks their end.
  * Autocommit is off inside `Repo.transaction/2` until COMMIT or ROLLBACK.

### Protocol

  * Read responses until the protocol marks their end, using the end of
    response marker of 26ai when the server offers it, instead of relying on
    `read_timeout`.
  * Decode row headers repeated between rows in `FOR UPDATE` fetches.
  * Fix TLS socket options and decode chunked RPA keywords.
  * Fix RAW binds corrupting the binds that follow them.

### Ecto adapter

  * Support `insert/8`, identity primary keys and `RETURNING` binds, returned
    as rows.
  * Support `values/2` sources.
  * Translate `json_extract_path` to `JSON_VALUE`.
  * Add configurable identifier quoting (`config :orax, quote_identifiers: true`).
  * Reject `select`, joins and CTEs in `update_all` and `delete_all`.
  * Report bare, Ecto-cased constraint names in `to_constraints`.
  * Load Oracle `DATE` values into `:date` fields.
  * Return integers for integral unconstrained `NUMBER` values and map
    unconstrained decimal columns to `NUMBER`.
  * Convert `type/2` `:string` with `TO_CHAR` instead of `CAST`.
  * Fix text and binary handling and parameterized intervals.
