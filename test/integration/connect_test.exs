defmodule Orax.Integration.ConnectTest do
  use ExUnit.Case, async: true

  @moduletag :oracle
  @moduletag :capture_log

  # Wrong credentials use a user that does not exist: failed logins of a real
  # user count towards locking its account.
  @no_such_user "orax_no_such_user"

  alias Orax.Integration

  defp config(extra), do: Keyword.merge(Integration.config(), extra)

  test "wrong credentials are an error returned by connect" do
    assert {:error, %DBConnection.ConnectionError{message: "ORA-01017: " <> _}} =
             Orax.connect(config(username: @no_such_user))
  end

  test "a service the listener does not know is an error returned by connect" do
    assert {:error, %DBConnection.ConnectionError{message: message}} =
             Orax.connect(config(database: "ORAX_NO_SUCH_SERVICE"))

    assert message =~ ~s(ORA-12514: the listener does not know the service "ORAX_NO_SUCH_SERVICE")
  end

  test "a port nobody listens on is an error returned by connect" do
    assert {:error, %DBConnection.ConnectionError{message: message}} =
             Orax.connect(config(hostname: "127.0.0.1", port: 1))

    assert message == "tcp connect (127.0.0.1:1): connection refused - :econnrefused"
  end

  # Failed connections are retried with a backoff, the pool stays up.
  test "a pool that cannot connect stays up and reports the error" do
    {:ok, pool} =
      DBConnection.start_link(
        Orax,
        config(
          database: "ORAX_NO_SUCH_SERVICE",
          pool_size: 2,
          backoff_min: 10,
          backoff_max: 10,
          queue_target: 50,
          queue_interval: 50
        )
      )

    Process.sleep(300)
    assert Process.alive?(pool)

    assert {:error, %DBConnection.ConnectionError{}} =
             DBConnection.execute(pool, %Orax.Query{statement: "SELECT 1 FROM dual"}, [])

    GenServer.stop(pool)
  end

  test "the Erlang API returns the error of start_link to the caller" do
    Process.flag(:trap_exit, false)

    opts = [
      host: ~c"#{config([])[:hostname]}",
      port: config([])[:port],
      user: ~c"#{@no_such_user}",
      password: ~c"wrong",
      service_name: ~c"#{config([])[:database]}"
    ] ++ config([])[:parameters]

    assert {:error, [{:proc_result, 1017, _}]} = :orax.start_link(opts)
    assert Process.alive?(self())
  end
end
