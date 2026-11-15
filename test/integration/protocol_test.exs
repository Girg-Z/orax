defmodule Orax.Integration.ProtocolTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  alias Orax.Integration

  # Forwards a TCP connection to the database. When the counter is set, the
  # next data packet from the server gets an unknown message type, so its
  # response cannot be decoded.
  defmodule CorruptingProxy do
    def start(target_port) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      corrupt = :atomics.new(1, [])
      spawn_link(fn -> accept(listen, target_port, corrupt) end)
      {port, corrupt}
    end

    defp accept(listen, target_port, corrupt) do
      {:ok, client} = :gen_tcp.accept(listen)
      {:ok, server} = :gen_tcp.connect(~c"127.0.0.1", target_port, [:binary, active: false])
      spawn_link(fn -> pipe(client, server, nil) end)
      pipe(server, client, corrupt)
    end

    defp pipe(from, to, corrupt) do
      case :gen_tcp.recv(from, 0) do
        {:ok, data} ->
          :gen_tcp.send(to, corrupt(data, corrupt))
          pipe(from, to, corrupt)

        {:error, _} ->
          :gen_tcp.close(to)
      end
    end

    # 8 bytes of packet header (type at offset 4), 2 bytes of data flags,
    # then the first message type.
    defp corrupt(<<header::binary-size(4), 6, rest::binary-size(5), _type, data::binary>> = packet, corrupt)
         when corrupt != nil do
      case :atomics.compare_exchange(corrupt, 1, 1, 0) do
        :ok -> <<header::binary, 6, rest::binary, 0xEE, data::binary>>
        _ -> packet
      end
    end

    defp corrupt(data, _corrupt), do: data
  end

  defp opts(extra) do
    config = Integration.config()

    [
      host: String.to_charlist(config[:hostname]),
      port: config[:port],
      user: String.to_charlist(config[:username]),
      password: String.to_charlist(config[:password]),
      service_name: String.to_charlist(config[:database]),
      timeout: 15_000
    ] ++ extra
  end

  defp start(extra) do
    {:ok, conn} = :orax.start(opts(extra))
    on_exit(fn -> stop(conn) end)
    conn
  end

  defp stop(conn) do
    :orax.stop(conn)
  catch
    :exit, _ -> :ok
  end

  defp assert_usable(conn) do
    assert {:ok, [{:result_set, _, _, [[~c"ok"]]}]} =
             :orax.sql_query(conn, ~c"SELECT 'ok' FROM dual", 15_000)
  end

  # 23ai marks the end of each response; without it (19c and earlier) the
  # driver finds the end of the call from the messages.
  for eor <- [true, false] do
    describe "end_of_response: #{eor}" do
      @describetag end_of_response: eor

      test "the call timeout breaks the call off and keeps the connection", %{end_of_response: eor} do
        conn = start(end_of_response: eor)
        sql = ~c"BEGIN dbms_session.sleep(1.4); END;"

        assert {:error, :timeout, _reason} = :orax.sql_query(conn, sql, 1_000)
        assert_usable(conn)
      end

      test "an error raised during the fetch is returned after the break", %{end_of_response: eor} do
        conn = start(end_of_response: eor)
        sql = ~c"SELECT 1/(level-3) FROM dual CONNECT BY level <= 5"

        assert {:ok, [{:proc_result, 1476, _message}]} = :orax.sql_query(conn, sql, 15_000)
        assert_usable(conn)
      end

      test "a response that does not decode is an error and keeps the connection",
           %{end_of_response: eor} do
        config = Integration.config()
        {proxy_port, corrupt} = CorruptingProxy.start(config[:port])
        {:ok, conn} = :orax.start(Keyword.put(opts(end_of_response: eor), :port, proxy_port))
        on_exit(fn -> stop(conn) end)

        :atomics.put(corrupt, 1, 1)

        assert {:error, :local, {:decode_error, details}} =
                 :orax.sql_query(conn, ~c"SELECT 1 FROM dual", 15_000)

        assert details[:message_type] == 0xEE
        assert_usable(conn)
      end

      # The response ends with an error message (ORA-01403); over this range
      # of sizes the packet boundary falls on every byte of the messages at
      # the end of the response (the second packet carries n - 7834 bytes).
      test "responses ending on any byte of a packet are read whole", %{end_of_response: eor} do
        conn = start(end_of_response: eor)

        for n <- 7750..8000 do
          sql = ~c"SELECT RPAD('x', 4000, 'x'), RPAD('y', #{n - 4000}, 'y') FROM dual"
          {micros, result} = :timer.tc(fn -> :orax.sql_query(conn, sql, 15_000) end)

          assert {:ok, [{:result_set, _, _, [[x, y]]}]} = result
          assert {length(x), length(y)} == {4000, min(n - 4000, 4000)}
          assert micros < 300_000, "#{n}: #{div(micros, 1000)} ms"
        end
      end
    end
  end
end
