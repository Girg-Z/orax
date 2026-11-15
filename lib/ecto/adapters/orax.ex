defmodule Ecto.Adapters.Orax do
  @moduledoc """
  Adapter module for Oracle. `Ecto.Adapters.SQL` callbacks implementation.

  It uses `orax` for communicating to the database.

  """

  use Ecto.Adapters.SQL, driver: Orax, migration_lock: nil

  @impl true
  def insert(adapter_meta, schema_meta, params, on_conflict, returning, opts) do
    super(adapter_meta, schema_meta, params, on_conflict, returning,
      returning_options(opts, schema_meta, returning))
  end

  @impl true
  def update(adapter_meta, schema_meta, fields, params, returning, opts) do
    super(adapter_meta, schema_meta, fields, params, returning,
      returning_options(opts, schema_meta, returning))
  end

  @impl true
  def delete(adapter_meta, schema_meta, params, returning, opts) do
    super(adapter_meta, schema_meta, params, returning,
      returning_options(opts, schema_meta, returning))
  end

  # Several rows are inserted with the INSERT of one row executed for each of
  # them in a single round trip (array DML, python-oracledb's executemany):
  # it works on 19c and 26ai and returns the RETURNING values of every row.
  # Rows that leave out different fields (DEFAULT) or hold different
  # subqueries need INSERTs of their own: consecutive rows of the same shape
  # are batched together and the batches run in a transaction.
  @impl true
  def insert_all(adapter_meta, schema_meta, header, [_, _ | _] = rows, on_conflict, returning,
      placeholders, opts) do
    %{source: source, prefix: prefix} = schema_meta
    opts = [batch: true, source: source] ++ returning_options(opts, schema_meta, returning)

    batches =
      rows
      |> Enum.map(&insert_row(header, &1))
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(fn [{shape, _} | _] = batch ->
        sql = Ecto.Adapters.Orax.Connection.insert(prefix, source, header, [shape], on_conflict,
          returning, placeholders)
        {sql, Enum.map(batch, fn {_, params} -> placeholders ++ params end)}
      end)

    run = fn ->
      Enum.reduce(batches, {0, []}, fn {sql, params}, {count, acc} ->
        %{num_rows: num, rows: rows} = Ecto.Adapters.SQL.query!(adapter_meta, sql, params, opts)
        {count + num, acc ++ (rows || [])}
      end)
    end

    {count, rows} =
      case batches do
        [_] -> run.()
        _ ->
          {:ok, result} = Ecto.Adapters.SQL.transaction(adapter_meta, opts, run)
          result
      end

    {count, if(returning == [], do: nil, else: rows)}
  end

  def insert_all(adapter_meta, schema_meta, header, rows, on_conflict, returning,
      placeholders, opts) do
    super(adapter_meta, schema_meta, header, rows, on_conflict, returning, placeholders,
      returning_options(opts, schema_meta, returning))
  end

  # The values of a row in the order of the header (Ecto.Adapters.SQL's
  # unzip_inserts): nil for fields left out (DEFAULT), subqueries and
  # placeholders as they are, the other fields as binds; and its params.
  defp insert_row(header, fields) do
    {shape, params} =
      Enum.map_reduce(header, [], fn key, acc ->
        case :lists.keyfind(key, 1, fields) do
          {^key, {%Ecto.Query{} = query, query_params}} ->
            {{query, length(query_params)}, Enum.reverse(query_params, acc)}

          {^key, {:placeholder, placeholder_index}} ->
            {{:placeholder, Integer.to_string(placeholder_index)}, acc}

          {^key, value} ->
            {key, [value | acc]}

          false ->
            {nil, acc}
        end
      end)

    {shape, Enum.reverse(params)}
  end

  @doc false
  def returning_options(opts, _schema_meta, []), do: opts
  def returning_options(opts, schema_meta, returning) do
    opts = Keyword.put(opts, :out_rows, true)

    if Keyword.has_key?(opts, :out) do
      opts
    else
      Keyword.put(opts, :out, returning_types(schema_meta, returning))
    end
  end

  defp returning_types(%{schema: nil}, returning) do
    Enum.map(returning, fn
      {_field, type} -> output_type(type)
      field ->
        raise ArgumentError,
          "cannot infer the Oracle output type for returning field #{inspect(field)} " <>
          "without a schema; use a {field, type} tuple or pass the :out option"
    end)
  end
  defp returning_types(%{schema: schema}, returning) when is_atom(schema) do
    source_types = schema.__schema__(:dump)
      |> Map.new(fn {_field, {source, type, _writable}} -> {source, type} end)

    Enum.map(returning, fn source ->
      source_types |> Map.fetch!(source) |> output_type()
    end)
  end

  defp output_type(type) do
    case Ecto.Type.type(type) do
      type when type in [:id, :integer] -> :integer
      :float -> :float
      :decimal -> :decimal
      type when type in [:string, :boolean] -> :string
      type when type in [:binary, :binary_id] -> :binary
      :date -> :date
      type when type in [:time, :time_usec] -> :date
      type when type in [:naive_datetime, :naive_datetime_usec] -> :timestamp
      type when type in [:utc_datetime, :utc_datetime_usec] -> :timestamptz
      :map -> :clob
      {:map, _} -> :clob
      type -> raise ArgumentError, "unsupported Oracle output type #{inspect(type)}"
    end
  end

  @impl true
  def ensure_all_started(config, type) do
    Ecto.Adapters.SQL.ensure_all_started(:orax, config, type)
  end

  @impl true
  def loaders({:embed, _}, type), do: [&json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
  def loaders({:map, _}, type),   do: [&json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
  def loaders(:map, type),        do: [&json_decode/1, type]
  def loaders(:float, type),      do: [&float_decode/1, type]
  def loaders(:boolean, type),    do: [&bool_decode/1, type]
  def loaders(:binary_id, type),  do: [Ecto.UUID, type]
  def loaders(:date, type),       do: [&date_decode/1, type]
  def loaders(_, type),           do: [type]

  @impl true
  def dumpers({:map, _}, type),   do: [&Ecto.Type.embedded_dump(type, &1, :json)]
  def dumpers(:binary, type),     do: [type, &tag_binary/1]
  def dumpers(:binary_id, type),  do: [type, Ecto.UUID]
  def dumpers(_, type),           do: [type]

  defp tag_binary(nil), do: {:ok, nil}
  defp tag_binary(value), do: {:ok, %Ecto.Query.Tagged{value: value, type: :binary}}

  defp bool_decode("0"), do: {:ok, false}
  defp bool_decode("1"), do: {:ok, true}
  defp bool_decode(0), do: {:ok, false}
  defp bool_decode(1), do: {:ok, true}
  defp bool_decode(x), do: {:ok, x}

  # Oracle DATE always has a time part and is returned as a NaiveDateTime.
  defp date_decode(%NaiveDateTime{} = datetime), do: {:ok, NaiveDateTime.to_date(datetime)}
  defp date_decode(%DateTime{} = datetime), do: {:ok, DateTime.to_date(datetime)}
  defp date_decode(x), do: {:ok, x}

  defp float_decode(%Decimal{} = decimal), do: {:ok, Decimal.to_float(decimal)}
  defp float_decode(x), do: {:ok, x}

  defp json_decode(x) when is_binary(x), do: {:ok, Orax.json_library().decode!(x)}
  defp json_decode(x), do: {:ok, x}

  @impl true
  def lock_for_migrations(_meta, _opts, fun), do: fun.()

  @impl true
  def supports_ddl_transaction? do
    false
  end

end

defmodule Ecto.Adapters.Orax.Connection do
  @moduledoc false

  @behaviour Ecto.Adapters.SQL.Connection

  @impl true
  def child_spec(opts) do
    DBConnection.child_spec(Orax, opts)
  end

  @impl true
  def execute(conn, query, params, opts) do
    DBConnection.execute(conn, query!(query, "", opts), params, opts)
  end

  @impl true
  def prepare_execute(conn, name, query, params, opts) do
    DBConnection.prepare_execute(conn, query!(query, name, opts), params, opts)
  end

  @impl true
  def stream(conn, query, params, opts) do
    DBConnection.stream(conn, query!(query, "", opts), params, opts)
  end

  @impl true
  def query(conn, query, params, opts) do
    case DBConnection.prepare_execute(conn, query!(query, "", opts), params, opts) do
      {:ok, _, result}  -> {:ok, result}
      {:error, err} -> {:error, err}
    end
  end

  @impl true
  def query_many(_conn, _query, _params, _opts) do
    error!(nil, "query_many is not supported")
  end

  @impl true
  def explain_query(conn, query, params, opts) do
    case query(conn, IO.iodata_to_binary(["EXPLAIN PLAN FOR ", query]), params, opts) do
      {:ok, _result} -> query(conn, "SELECT * FROM table(DBMS_XPLAN.DISPLAY())", params, opts)
      {:error, err} -> {:error, err}
    end
  end

  defp query!(sql, name, opts) when is_binary(sql) or is_list(sql) do
    %Orax.Query{statement: IO.iodata_to_binary(sql), name: name, batch: opts[:batch]}
  end
  defp query!(%{} = query, _name, _opts) do
    query
  end

  defp error!(nil, msg) do
    raise ArgumentError, msg
  end

  @impl true
  defdelegate all(query), to: Orax.Query
  @impl true
  defdelegate update_all(query), to: Orax.Query
  @impl true
  defdelegate delete_all(query), to: Orax.Query
  @impl true
  defdelegate insert(prefix, table, header, rows, on_conflict, returning, placeholders,
    opts \\ []), to: Orax.Query
  @impl true
  defdelegate update(prefix, table, fields, filters, returning), to: Orax.Query
  @impl true
  defdelegate delete(prefix, table, filters, returning), to: Orax.Query
  @impl true
  defdelegate table_exists_query(table), to: Orax.SQL
  @impl true
  defdelegate execute_ddl(command), to: Orax.SQL
  @impl true
  defdelegate ddl_logs(result), to: Orax.SQL
  @impl true
  defdelegate to_constraints(err, opts), to: Orax.SQL

end
