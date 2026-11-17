defmodule Orax do
  @moduledoc """
  Adapter module for Oracle. `DBConnection` behaviour implementation.

  It uses `orax` for communicating to the database.

  """

  use DBConnection

  @timeout 15_000
  @idle_interval 5_000

  # The connection runs in the DBConnection process, as with Postgrex: `conn`
  # is the state of `orax_conn`, which owns the socket.
  defstruct [:conn, :mode, :cursors, :timeout, :idle_interval, autocommit: 1]

  @doc """
  Starts and links to a database connection process.

  See [`Ecto.Adapters.Orax`](Ecto.Adapters.Orax.html#module-connection-options).

  By default the `DBConnection` starts a pool with a single connection.
  The size of the pool can be increased with `:pool_size`. The ping interval 
  to validate an idle connection can be given with the `:idle_interval` option.
  """
  @spec start_link(opts :: Keyword.t) :: 
    {:ok, pid()} | {:error, any()}
  def start_link(opts) do
    DBConnection.start_link(Orax, opts)
  end

  # Runs a statement, a driver command (COMMIT, COMOFF...) or a fetch, and
  # returns the state with the connection after it.
  defp query(s, sql, params \\ []) do
    case request(s, stmt(sql, params), s.timeout) do
      {:ok, [{:result_set, columns, _, rows}], s} ->
        {:ok, %{num_rows: length(rows), rows: rows, columns: columns}, s}
      {:ok, [{:fetched_rows, _, _, _} = result], s} -> {:cont, result, s}
      {:ok, [{:proc_result, 0, rows}], s} -> {:ok, %{num_rows: length(rows), rows: rows}, s}
      {:ok, [{:proc_result, _, msg}], s} -> {:error, msg, s}
      {:ok, [{:affected_rows, num_rows}], s} -> {:ok, %{num_rows: num_rows, rows: nil}, s}
      {:ok, result, s} -> {:ok, result, s}
      {:error, type, err, s} when type in [:timeout, :local] -> {:error, err, s}
      {:error, _type, err, s} -> {:disconnect, err, s}
    end
  end

  defp request(%{conn: conn} = s, query, timeout) do
    case :orax_conn.sql_query(conn, query, timeout) do
      {:ok, result, conn} -> {:ok, result, %{s | conn: conn}}
      {:error, type, err, conn} -> {:error, type, err, %{s | conn: conn}}
    end
  catch
    # the state of the connection is unknown: it is closed
    kind, reason -> {:error, :socket, {kind, reason, Enum.take(__STACKTRACE__, 5)}, s}
  end

  defp stmt({:fetch, sql, params}, _), do: {:fetch, sql, params}
  defp stmt({:fetch, cursor, row_format, last_row}, _), do: {:fetch, cursor, row_format, last_row}
  defp stmt({:batch, sql, params}, _), do: {:batch, sql, params}
  defp stmt(sql, params), do: {sql, params}
  
  @impl true
  def connect(opts) do
    host = opts[:hostname] |> Orax.to_list
    port = opts[:port]
    timeout = opts[:timeout] || @timeout
    idle_interval = opts[:idle_interval] || @idle_interval
    user = opts[:username] |> Orax.to_list
    password = opts[:password] |> Orax.to_list
    database = opts[:database] |> Orax.to_list
    env = [host: host, port: port, user: user, password: password, timeout: timeout, idle_interval: idle_interval]
	  ++ if( hd(database) == ?:, do: [sid: tl(database)], else: [service_name: database] )
    params = opts[:parameters] || []
    sock_opts = opts[:socket_options] || []
    case :orax_conn.connect(sock_opts ++ params ++ env) do
      {:ok, conn} ->
        {:ok, %Orax{conn: conn, mode: :idle, timeout: timeout, idle_interval: idle_interval,
          autocommit: Keyword.get(params, :autocommit, 1)}}
      {:ok, err, _conn} -> {:error, connect_error(err, opts)}
      {:error, _type, err, _conn} -> {:error, connect_error(err, opts)}
    end
  end

  # Login errors come as the ORA error of the server; a listener refusing the
  # connection answers with a description holding the error number, e.g.
  # (DESCRIPTION=(TMP=)(VSNNUM=0)(ERR=12514)(ERROR_STACK=...)).
  defp connect_error([{:proc_result, _code, message}], _opts),
    do: error!(String.trim_trailing(message))
  defp connect_error(description, opts) when is_binary(description) do
    case Regex.run(~r/\(ERR=(\d+)\)/, description) do
      [_, code] ->
        error!("ORA-#{String.pad_leading(code, 5, "0")}: #{refusal(code, opts)} #{description}")
      nil ->
        error!(description)
    end
  end
  defp connect_error(reason, opts) do
    message = if is_atom(reason), do: "#{:inet.format_error(reason)} - #{inspect(reason)}", else: inspect(reason)
    error!("tcp connect (#{opts[:hostname]}:#{opts[:port]}): #{message}")
  end

  defp refusal("12514", opts),
    do: "the listener does not know the service #{inspect(opts[:database])}"
  defp refusal("12505", opts),
    do: "the listener does not know the SID #{inspect(opts[:database])}"
  defp refusal(code, _opts) when code in ["12516", "12519", "12520"],
    do: "the listener has no handler for the connection (has the database reached its processes limit?)"
  defp refusal(_code, _opts),
    do: "the listener refused the connection"

  @impl true
  def disconnect(_err, %{conn: conn}) do
    :orax_conn.disconnect(conn, 1)
    :ok
  catch
    _, _ -> :ok
  end

  # Out binds come back as one list per bind, each holding a value for every
  # affected row. Ecto expects one list per row, so transpose when asked to.
  defp out_rows(%{rows: [_ | _] = columns} = result, opts) do
    if Keyword.get(opts, :out_rows, false) do
      rows = Enum.zip_with(columns, & &1)
      %{result | num_rows: length(rows), rows: rows}
    else
      result
    end
  end
  defp out_rows(result, _opts), do: result

  # A batch executes the statement once for each row of params in a single
  # round trip (array DML). When a row fails, the server keeps the changes of
  # the rows before it, so they are undone to leave the batch atomic: rolled
  # back under autocommit, rolled back to a savepoint taken before the batch
  # otherwise.
  @impl true
  def handle_execute(%{batch: true} = query, params, opts, s) do
    %Orax.Query{statement: statement} = query
    returning = Enum.map(Keyword.get(opts, :out, []), fn elem -> {:out, elem} end)
    batch = {:batch, statement |> Orax.to_list, Enum.map(params, &(&1 ++ returning))}
    case atomic(s, length(params), &query(&1, batch)) do
      {:ok, result, s} -> {:ok, query, out_rows(result, opts), s}
      {:error, err, s} -> {:error, error!(err), s}
      {:disconnect, err, s} -> {:disconnect, error!(err), s}
    end
  end
  def handle_execute(query, params, opts, s) do
    %Orax.Query{statement: statement} = query
    returning = Enum.map(Keyword.get(opts, :out, []), fn elem -> {:out, elem} end)
    case query(s, statement |> Orax.to_list, Enum.concat(params, returning)) do
      {:ok, result, s} -> {:ok, query, out_rows(result, opts), s}
      {:error, err, s} -> {:error, error!(err), s}
      {:disconnect, err, s} -> {:disconnect, error!(err), s}
    end
  end

  defp atomic(s, 1, fun), do: fun.(s)
  defp atomic(%{mode: :idle, autocommit: 1} = s, _rows, fun) do
    case fun.(s) do
      {:error, err, s} -> undo(s, ~c"ROLLBACK", err)
      result -> result
    end
  end
  defp atomic(s, _rows, fun) do
    with {:ok, _, s} <- query(s, ~c"SAVEPOINT orax_batch") do
      case fun.(s) do
        {:error, err, s} -> undo(s, ~c"ROLLBACK TO orax_batch", err)
        result -> result
      end
    end
  end

  defp undo(s, statement, err) do
    case query(s, statement) do
      {:disconnect, _err, _s} = disconnect -> disconnect
      {_status, _result, s} -> {:error, err, s}
    end
  end

  @impl true
  def handle_prepare(query, opts, s) do
    timeout = opts[:timeout] || @timeout
    {:ok, query, %{s | timeout: timeout}}
  end

  # Transactions
  #
  # Outside a transaction every statement is committed by the server (the
  # `:autocommit` connection parameter, on by default). A transaction turns
  # autocommit off on the connection, so nothing is committed until COMMIT and
  # ROLLBACK discards everything done since BEGIN; autocommit is restored
  # afterwards. Savepoints (`mode: :savepoint`, used by Ecto's SQL sandbox) map
  # to SAVEPOINT / ROLLBACK TO; Oracle has no RELEASE SAVEPOINT, so releasing
  # one is a no-op. Note that DDL statements implicitly commit in Oracle, also
  # inside a transaction.

  @impl true
  def handle_begin(opts, %{mode: mode} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when mode == :idle ->
        case autocommit(s, :off) do
          {:ok, result, s} -> {:ok, result, %{s | mode: :transaction}}
          other -> other
        end
      :savepoint when mode == :transaction ->
        statement = "SAVEPOINT " <> Keyword.get(opts, :name, "svpt")
        handle_transaction(statement, opts, s)
      _status ->
        # report the actual transaction status of the connection
        {mode, s}
    end
  end

  @impl true
  def handle_commit(opts, %{mode: mode} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when mode == :transaction ->
        end_transaction("COMMIT", opts, s)
      :savepoint when mode == :transaction ->
        {:ok, [], s}
      _status ->
        # report the actual transaction status of the connection
        {mode, s}
    end
  end

  @impl true
  def handle_rollback(opts, %{mode: mode} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when mode in [:transaction, :error] ->
        end_transaction("ROLLBACK", opts, s)
      :savepoint when mode in [:transaction, :error] ->
        statement = "ROLLBACK TO " <> Keyword.get(opts, :name, "svpt")
        handle_transaction(statement, opts, %{s | mode: :transaction})
      _status ->
        # report the actual transaction status of the connection
        {mode, s}
    end
  end

  # COMMIT or ROLLBACK ends the transaction even when it fails (Oracle rolls
  # back a transaction whose commit fails), so autocommit is restored anyway.
  defp end_transaction(statement, opts, s) do
    case handle_transaction(statement, opts, s) do
      {:disconnect, _err, _s} = disconnect ->
        disconnect
      {status, result, s} ->
        case autocommit(%{s | mode: :idle}, :on) do
          {:ok, _, s} -> {status, result, s}
          other -> other
        end
    end
  end

  # The driver commands COMOFF / COMON switch the commit-on-execute flag of
  # the connection; nothing to do when autocommit was disabled in the config.
  defp autocommit(%{autocommit: 0} = s, _), do: {:ok, [], s}
  defp autocommit(s, :off), do: handle_transaction("COMOFF", [], s)
  defp autocommit(s, :on), do: handle_transaction("COMON", [], s)

  defp handle_transaction(statement, _opts, s) do
    case query(s, statement |> Orax.to_list) do
      {:ok, result, s} -> {:ok, result, s}
      {:error, err, s} -> {:error, error!(err), s}
      {:disconnect, err, s} -> {:disconnect, error!(err), s}
    end
  end

  @impl true
  def handle_declare(query, params, _opts, s) do
    {:ok, query, %{params: params}, s}
  end

  @impl true
  def handle_fetch(query, %{params: params}, _opts, %{cursors: nil} = s) do
    %Orax.Query{statement: statement} = query
    case query(s, {:fetch, statement |> Orax.to_list, params}) do
      {:cont, {_, cursor, row_format, rows}, s} ->
        cursors = %{cursor: cursor, row_format: row_format, last_row: List.last(rows)}
        {:cont,  %{num_rows: length(rows), rows: rows}, %{s | cursors: cursors}}
      {:ok, result, s} -> 
        {:halt, result, s}
      {:error, err, s} -> {:error, error!(err), s}
      {:disconnect, err, s} -> {:disconnect, error!(err), s}
    end
  end
  def handle_fetch(_query, _cursor, _opts, %{cursors: cursors} = s) do
    %{cursor: cursor, row_format: row_format, last_row: last_row} = cursors
    case query(s, {:fetch, cursor, row_format, last_row}) do
      {:cont, {_, _, _, rows}, s} ->
        rows = tl(rows)
        {:cont,  %{num_rows: length(rows), rows: rows}, 
        %{s | cursors: %{cursors | last_row: List.last(rows)}}}
      {:ok, %{rows: rows} = result, s} -> 
        rows = tl(rows)
        {:halt, %{result | num_rows: length(rows), rows: rows}, s}
      {:error, err, s} -> {:error, error!(err), s}
      {:disconnect, err, s} -> {:disconnect, error!(err), s}
    end
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, s) do
    {:ok, nil, %{s | cursors: nil}}
  end

  @impl true
  def handle_close(_query, _opts, s) do
    {:ok, nil, s}
  end

  @impl true
  def handle_status(_opts, %{mode: mode} = s) do
    {mode, s}
  end

  @doc false
  def checkin(s) do
    {:ok, s}
  end

  @impl true
  def checkout(%{timeout: timeout} = s) do
    case request(s, ~c'SESSION', timeout) do
      {:ok, _, s} -> {:ok, s}
      {:error, _type, err, s} -> {:disconnect, error!(err), s}
    end
  end

  @impl true
  def ping(%{timeout: timeout, idle_interval: idle_interval} = s) do
    case request(s, ~c'PING', min(timeout, idle_interval)) do
      {:ok, _, s} -> {:ok, s}
      {:error, _type, err, s} -> {:disconnect, error!(err), s}
    end
  end

  defp error!(msg) when is_binary(msg), do: DBConnection.ConnectionError.exception(msg)
  defp error!(msg), do: DBConnection.ConnectionError.exception(inspect(msg))

  @doc """
  Returns the configured JSON library.

  To customize the JSON library, include the following in your `config/config.exs`:

      config :orax, :json_library, SomeJSONModule

  Defaults to Elixir's built-in `JSON`. The module must provide `encode!/1`
  and `decode!/1`, as `Jason` does.
  """
  @spec json_library() :: module()
  def json_library() do
    Application.get_env(:orax, :json_library, JSON)
  end

  @doc """
  Strip single/multiline comments
  """
  @spec strip(sql :: String.t) :: String.t
  def strip(sql) do
    sql = Regex.replace(~r"--.*", sql, "")
    sql = Regex.replace(~r"(?s)/\*.*?\*/", sql, "")
    sql
  end

  @doc false
  def to_list(string) when is_binary(string) do
    :binary.bin_to_list(string)
  end

  @doc false
  defdelegate loaders(t, type), to: Ecto.Adapters.Orax
  @doc false
  defdelegate dumpers(t, type), to: Ecto.Adapters.Orax

end

defimpl DBConnection.Query, for: Orax.Query do

  def parse(query, _), do: query
  def describe(query, _), do: query

  def decode(_, %{rows: []} = result, _), do: result
  def decode(_, %{rows: rows} = result, opts) when rows != nil, 
    do: %{result | rows: Enum.map(rows, fn row -> decode(row, opts[:decode_mapper]) end)}
  def decode(_, result, _), do: result

  defp decode(row, nil), do: Enum.map(row, fn elem -> decode(elem) end)
  defp decode(row, mapper), do: mapper.(decode(row, nil))

  defp decode(:null), do: nil
  defp decode({format, values} = vector) when format in [:float32, :float64, :int8] and is_list(values),
    do: Orax.Vector.from_driver(vector)
  defp decode({:binary, values} = vector) when is_binary(values), do: Orax.Vector.from_driver(vector)
  defp decode({:sparse, _, _, _, _} = vector), do: Orax.Vector.from_driver(vector)
  defp decode({date, time}) when is_tuple(date), do: to_naive({date, time})
  defp decode({date, time, tz}) when is_tuple(date), do: to_date({date, time, tz})
  defp decode(elem), do: elem

  def encode(_, [], _), do: []
  def encode(_, [%Ecto.Query.Tagged{value: params, type: :map}], _), do: [params]
  def encode(_, params, opts) do
    types = Keyword.get(opts, :in, [])
    case Keyword.get(opts, :batch) do
      true -> Enum.map(params, fn row -> Enum.map(encode(row, types), fn elem -> encode(elem) end) end)
      _ -> Enum.map(encode(params, types), fn elem -> encode(elem) end)
    end
  end

  defp encode(params, []), do: params
  defp encode([%Ecto.Query.Tagged{type: :binary} = elem | next1], [_type | next2]),
    do: [ elem | encode(next1, next2)]
  defp encode([elem | next1], [type | next2]) when type in [:binary, :binary_id, Ecto.UUID],
    do: [ %Ecto.Query.Tagged{value: elem, type: :binary} | encode(next1, next2)]
  defp encode([elem | next1], [_type | next2]), do: [ elem | encode(next1, next2)]

  defp encode(nil), do: :null
  defp encode(true), do: "1"
  defp encode(false), do: "0"
  defp encode(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp encode(%DateTime{microsecond: {0, 0}, utc_offset: utc_offset, zone_abbr: "UTC"} = datetime) do
    {date, {hour, min, sec}} = NaiveDateTime.to_erl(DateTime.to_naive(datetime))
    {date, {hour, min, sec, 0}, utc_offset}
  end
  defp encode(%DateTime{microsecond: {ms, _}, utc_offset: utc_offset, zone_abbr: "UTC"} = datetime) do
    {date, {hour, min, sec}} = NaiveDateTime.to_erl(DateTime.to_naive(datetime))
    {date, {hour, min, sec, ms}, utc_offset}
  end
  defp encode(%NaiveDateTime{microsecond: {0, 0}} = naive),
    do: NaiveDateTime.to_erl(naive)
  defp encode(%NaiveDateTime{microsecond: {ms, _}} = naive) do
    {date, {hour, min, sec}} = NaiveDateTime.to_erl(naive)
    {date, {hour, min, sec, ms}}
  end
  defp encode(%Date{} = date), do: Date.to_erl(date)
  defp encode(%Ecto.Query.Tagged{value: elem, type: :binary}) when is_binary(elem), do: {:raw, elem}
  defp encode(%Orax.Vector{} = vector), do: Orax.Vector.to_driver(vector)
  defp encode(elem) when is_map(elem),
    do: Orax.json_library().encode!(elem) |> IO.iodata_to_binary()
  defp encode(elem), do: elem

  defp to_naive({date, {hour, min, sec}}) when is_integer(sec),
    do: NaiveDateTime.from_erl!({date, {hour, min, sec}})
  defp to_naive({date, {hour, min, sec}}),
    do: NaiveDateTime.from_erl!({date, {hour, min, trunc(sec)}}, parse_sec(sec))

  defp to_date({{year, month, day}, {hour, min, sec}, tz}),
    do: %DateTime{year: year, month: month, day: day, hour: hour, minute: min,
    second: trunc(sec), microsecond: parse_sec(sec), time_zone: "Etc/UTC",
    zone_abbr: "UTC", utc_offset: parse_offset(tz), std_offset: 0}

  defp parse_offset("Etc/UTC"), do: 0
  defp parse_offset(<<?+, hour::2-bytes, ?:, min::2-bytes, _rest::binary>>),
    do: parse_offset(1, hour, min)
  defp parse_offset(<<?-, hour::2-bytes, ?:, min::2-bytes, _rest::binary>>),
    do: parse_offset(-1, hour, min)
  defp parse_offset(_tz), do: 0

  defp parse_offset(sign, hour, min) do
    with {hour, ""} when hour < 24 <- Integer.parse(hour),
         {min, ""} when min < 60 <- Integer.parse(min) do
      (hour * 60 + min) * 60 * sign
    else
      _ -> :error
    end
  end

  defp parse_sec(sec),
    do: {trunc((sec - trunc(sec)) * 1000000) , 6}

end
