defmodule Orax.Integration.StorageTest do
  use ExUnit.Case, async: true

  @moduletag :oracle
  @moduletag :capture_log

  alias Ecto.Adapters.Orax, as: Adapter
  alias Orax.Integration

  # A user that does not exist: failed logins of a real user count towards
  # locking its account.
  @no_such_user "orax_no_such_user"

  defp config(extra \\ []), do: Keyword.merge(Integration.config(), extra)

  test "the storage of a user that logs in is up" do
    assert Adapter.storage_status(config()) == :up
    assert Adapter.storage_up(config()) == {:error, :already_up}
  end

  test "a user that cannot log in is an error that says who creates it" do
    assert {:error, message} = Adapter.storage_up(config(username: @no_such_user))
    assert message =~ "ORA-01017"
    assert message =~ ~s(check that the user "#{@no_such_user}" exists)

    assert {:error, "ORA-01017" <> _} = Adapter.storage_status(config(username: @no_such_user))
  end

  test "other connection errors are returned as they are" do
    assert {:error, "tcp connect (127.0.0.1:1): connection refused - :econnrefused"} =
             Adapter.storage_up(config(hostname: "127.0.0.1", port: 1))
  end

  test "dropping the storage is not supported" do
    assert {:error, message} = Adapter.storage_down(config())
    assert message =~ "not supported"
  end
end
