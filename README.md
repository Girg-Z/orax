# Orax

Erlang driver and Ecto adapter for Oracle Database.

Orax speaks the Oracle TNS protocol natively: it needs no Oracle Instant
Client, OCI or ODBC.

Orax is a fork of [jamdb_oracle](https://github.com/erlangbureau/jamdb_oracle)
by Mykhailo Vstavskyi and Sergiy Kostyushkin, who wrote the driver this
project is built on. Many thanks to them. See the [changelog](CHANGELOG.md)
for what changed since the fork.

## Requirements

  * Oracle Database 19c or 26ai (23ai). Older releases are not supported.
  * Elixir 1.18 or later, Erlang/OTP 27 or later.
  * ecto_sql 3.14 or later, for the Ecto adapter.

## Installation

Add `orax` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:orax, "~> 0.1.0"}
  ]
end
```

and configure your repository to use the adapter:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Orax
end

config :my_app, MyApp.Repo,
  hostname: "localhost",
  port: 1521,
  database: "FREEPDB1",
  username: "scott",
  password: "tiger"
```

## Migrating from jamdb_oracle

  * Replace the `:jamdb_oracle` dependency with `:orax`.
  * Replace `Ecto.Adapters.Jamdb.Oracle` with `Ecto.Adapters.Orax`,
    `Jamdb.Oracle` with `Orax` and the Erlang modules `jamdb_oracle_*` with
    `orax_*`.
  * Move `config :jamdb_oracle, ...` to `config :orax, ...`.
  * The JSON library defaults to Elixir's `JSON`; set
    `config :orax, :json_library, Jason` to keep Jason.
  * Remove `:read_timeout` from `:parameters`.

See the [changelog](CHANGELOG.md) for the other behaviour changes.

## Features

 * Using prepared statement functionality, the SQL statement you want
   to run is precompiled and stored in a database object, and you can run it
   as many times as required without compiling it every time it is run. If the data in the
   statement changes, you can use bind variables as placeholders for the data and then 
   provide literal values at run time.

 * Using bind variables:

    `{"insert into tabl values (:1)", [<<16#E7,16#99,16#BE>>]}`
* Using named parameters:

    `{"insert into tabl values (:id, :dat)", [#{dat => {2023, 1, 1}, id => 1}]}`
 * Calling stored procedure:

    `{"begin proc(:1, :2, :3); end;"`, `[1.0, 2.0, 3.0]}`
 * Calling stored function:

    `{"begin :1 := func(:2); end;"`, `[{:out, :varchar}, "one hundred"]}`
 * Using cursor variable:

    `{"begin open :1 for select * from tabl where dat>:2; end;"`, `[:cursor, {2016, 8, 1}]}`
 * Using returning clause:

    `{"insert into tabl values (tablid.nextval, sysdate) return id into :1"`, `[{:out, :number}]}`
 * Update batching:

    `{:batch, "insert into tabl values (:1, :2, :3)"`, `[[1, 2, 3],[4, 5, 6],[7, 8, 9]]}`
 * Row prefetching:

    `{:fetch, "select * from tabl where id>:1"`, `[1]}`

    `{:fetch, cursor, row_format, last_row}`

## Options

Adapter options split in different categories described
below. All options can be given via the repository
configuration:

    config :your_app, YourApp.Repo,
      ...

### Connection options

  * `:hostname` - Server hostname (Name or IP address of the database server)
  * `:port` - Server port (Number of the port where the server listens for requests)
  * `:database` - Database (Database service name or SID with colon as prefix)
  * `:username` - Username (Name for the connecting user)
  * `:password` - User password (Password for the connecting user)
  * `:parameters` - Keyword list of connection parameters
  * `:socket_options` - Options to be given to the underlying socket
  * `:timeout` - The default timeout to use on queries, defaults to `15000`.
    It bounds the whole call; when it expires the call is broken off and an error
    is returned, and the connection stays usable if the server answers the break
    within another timeout. Without out-of-band breaks the server only sees the
    break between operations, so a statement still running after twice the
    timeout closes the connection.

### Pool options

  * `:pool` - The connection pool module, defaults to `DBConnection.ConnectionPool`
  * `:pool_size` - The size of the pool, defaults to `1`
  * `:idle_interval` - The ping interval to validate an idle connection, defaults to `5000`	

### Connection parameters

  * `:autocommit` - Commit every statement executed outside a transaction, defaults to `1`.
    Inside `Repo.transaction/2` autocommit is always off until COMMIT / ROLLBACK.
    Note that Oracle implicitly commits DDL statements, also inside a transaction.
  * `:fetch` - Number of rows to fetch from the server
  * `:sdu` - Size of session data unit
  * `:end_of_response` - Use the end of response marker of Oracle Database 26ai
    (23ai) when the server offers it, defaults to `true`. 19c does not
    offer it; the end of each response is then found from its messages
  * `:role` - Mode that is used in an internal logon
  * `:prelim` - Mode that is permitted when the database is down
  * `:newpassword` - User new password (Change password for the connecting user)
  * `:proxy_user` - User name for proxy authentication
  * `:description` - Connect descriptor
  * `:charset` - Client character set, defaults to UTF-8

### TLS connections

When using TLS, start the OTP SSL application in the calling Mix application:

```elixir
def application do
  [
    extra_applications: [:logger, :ssl]
  ]
end
```

TLS options can be passed in `:parameters` under the `:ssl` key:

```elixir
parameters: [
  ssl: [
    verify: :verify_peer,
    server_name_indication: 'adb.example.oraclecloud.com', # charlist
    cacerts: :public_key.cacerts_get()
  ]
]
```

### Output parameters

* Calling stored procedure or function: `[{:out, :number}, {:out, :varchar}]`
* Using returning clause: `[{:out, :number}, {:out, :date}]`

For schema-based Ecto operations, output bind types for `RETURN ... INTO` are
inferred automatically from the schema. This includes identity primary keys
returned by `Repo.insert/2` and IDs needed by nested association inserts. The
`:out` option is still available for raw SQL and can be used to override the
inferred types.

Oracle types                     | Literal syntax in params
:------------------------------- | :-----------------------
`NUMBER`,`FLOAT`,`BINARY_FLOAT`  | `:number`, `:integer`, `:float`, `:decimal`
`CHAR`, `VARCHAR2`, `CLOB`       | `:varchar`, `:char`, `:clob`, `:string`
`NCHAR`, `NVARCHAR2`, `NCLOB`    | `:nvarchar`, `:nchar`, `:nclob`
`RAW`, `BLOB`                    | `:raw`, `:blob`, `:binary`, `:hexstring`
`DATE`                           | `:date`
`TIMESTAMP`                      | `:timestamp`
`TIMESTAMP WITH TIME ZONE`       | `:timestamptz`
`SYS_REFCURSOR`                  | `:cursor`

### Input parameters

Using query options: `[in: [:number, :binary]]`

### Primitive types

The primitive types are:

Ecto types              | Oracle types                     | Literal syntax in params
:---------------------- | :------------------------------- | :-----------------------
`:id`, `:integer`       | `NUMBER (*,0)`, `INTEGER`        | 1, 2, 3
`:float`                | `NUMBER`,`FLOAT`,`BINARY_FLOAT`  | 1.0, 2.0, 3.0
`:decimal`              | `NUMBER`,`FLOAT`,`BINARY_FLOAT`  | [`Decimal`](https://hexdocs.pm/decimal)
`:string`               | `CHAR`, `VARCHAR2`, `CLOB`       | "one hundred"
`:string`               | `NCHAR`, `NVARCHAR2`, `NCLOB`    | "百元", "万円"
`:binary`               | `RAW`, `BLOB`                    | "E799BE" (base 16 encoded)
`:binary`               | `RAW`, `BLOB`                    | <<0xE7,0x99,0xBE>> (option [in: [:binary])
`:binary_id`            | `RAW`, `BLOB`                    | <<231,153,190, ...>> (option [in: [:binary_id])
`:boolean`              | `CHAR`, `VARCHAR2`, `NUMBER`     | true, false
`:map`                  | `CLOB`, `NCLOB`                  | %{"one" => 1, "hundred" => "百"}
`:naive_datetime`       | `DATE`, `TIMESTAMP`              | [`NaiveDateTime`](https://hexdocs.pm/elixir)
`:utc_datetime`         | `TIMESTAMP WITH TIME ZONE`       | [`DateTime`](https://hexdocs.pm/elixir)

### Character sets

[`String`](https://hexdocs.pm/elixir) in Elixir is UTF-8 encoded binary.

`:us7ascii`, `:we8iso8859p1`, `:ee8iso8859p2`, `:nee8iso8859p4`, `:cl8iso8859p5`, `:ar8iso8859p6`,
`:el8iso8859p7`,`:iw8iso8859p8`, `:we8iso8859p9`, `:ne8iso8859p10`, `:th8tisascii`, `:vn8mswin1258`,
`:we8iso8859p15`,`:blt8iso8859p13`, `:ee8mswin1250`, `:cl8mswin1251`, `:el8mswin1253`, `:iw8mswin1255`,
`:tr8mswin1254`,`:we8mswin1252`, `:blt8mswin1257`, `:ar8mswin1256`

`:ja16euc`, `:ja16sjis`, `:ja16euctilde`,`:ja16sjistilde`,`:ko16mswin949`,
`:zhs16gbk`, `:zht32euc`, `:zht16big5`, `:zht16mswin950`, `:zht16hkscs`

#### Examples

    iex> Ecto.Adapters.SQL.query(YourApp.Repo, "select 1+:1,sysdate,rowid from dual where 1=:1 ", [1])
    {:ok, %{num_rows: 1, rows: [[2, ~N[2016-08-01 13:14:15], "AAAACOAABAAAAWJAAA"]]}}

    iex> row = [%Ecto.Query.Tagged{value: <<0xE7,0x99,0xBE>>, type: :binary}]
    iex> Ecto.Adapters.SQL.query(YourApp.Repo, "insert into tabl values (:1)", row)

    iex> row = [%Ecto.Query.Tagged{value: %{dat: {2023, 1, 1}, id: 1}, type: :map}]
    iex> Ecto.Adapters.SQL.query(YourApp.Repo, "insert into tabl values (:id, :dat)", row)
        
    iex> opts = [batch: true, in: [Ecto.UUID, :number]]
    iex> row = [Ecto.UUID.bingenerate, 1]
    iex> Ecto.Adapters.SQL.query(YourApp.Repo, "insert into tabl values (:1, :2)",
    ...> [row, row], opts)
        
    iex> opts = [returning: false, out: [:integer]]
    iex> row = [Date.utc_today]
    iex> Ecto.Adapters.SQL.query(YourApp.Repo, "insert into tabl (dat) values (:1) return id into :2",
    ...> row, opts)

Using quoted identifiers:

To quote every table, prefix, column, index, and constraint identifier generated
by the adapter, enable:

    config :orax, quote_identifiers: true

The option defaults to `false` for compatibility with existing Oracle schemas.
Quoted identifiers preserve the configured case, so `"users"` and `"USERS"`
refer to different objects in Oracle. Keep the same setting when running
migrations and application queries.

With the option disabled, individual identifiers can still be supplied with
explicit quotes as in the legacy example below:

    defmodule YourApp.Users do
      use Ecto.Schema

      schema "\\"USERS\\"" do
        field :id, :integer
        field :uuid, :binary_id
        field :name, :string, source: :'"NAME"'
        field :namae, :string, source: :'"名まえ"'
      end

    end

    iex> YourApp.Repo.all(from(u in "\\"USERS\\"", select: u.'"NAME"', where: u.id == 1))

    iex> YourApp.Repo.all(from(u in YourApp.Users, select: u.namae, where: u.id == 1))

    iex> uuid = "601d74e4-a8d3-4b6e-8365-eddb4c893327"
    iex> YourApp.Repo.all(from(u in YourApp.Users, select: u.name,
    iex> where: u.uuid == type(^uuid, :binary_id)), [in: [:binary_id]])

Imagine you have this migration:

    defmodule YourApp.Repo.Migrations.Users do
      use Ecto.Migration

      def change do
        create table(:users, comment: "users table") do
          add :name, :string, comment: "name column"
          add :namae, :string, national: true
          add :custom_id, :uuid
          timestamps()
        end
      end

    end

To migrate you'd do it normally:

    $ mix ecto.migrate

The implicit `:bigserial` primary key added by Ecto is created as an Oracle
`GENERATED BY DEFAULT AS IDENTITY` column.

## Running the tests

Unit tests need no database:

    $ mix test

Integration tests are tagged `:oracle` and run against an Oracle Database
Free container:

    $ docker run -d --name orax-test-db -p 1521:1521 -e ORACLE_PWD=OraxTest1 \
        container-registry.oracle.com/database/free:latest-lite
    $ docker cp test/support/create_test_user.sql orax-test-db:/tmp/
    $ docker exec orax-test-db sqlplus -s system/OraxTest1@//localhost:1521/FREEPDB1 \
        @/tmp/create_test_user.sql
    $ mix test --include oracle

The connection can be changed with the `ORAX_TEST_HOST`, `ORAX_TEST_PORT`,
`ORAX_TEST_USER`, `ORAX_TEST_PASSWORD` and `ORAX_TEST_DATABASE` environment
variables.

## License

MIT, see [LICENSE](LICENSE).
