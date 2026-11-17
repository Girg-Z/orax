defmodule OraxTransactionTest do
  use ExUnit.Case, async: true

  # The statements sent for transactions and savepoints are tested against a
  # real database in test/integration/transaction_test.exs.

  defp state(fields), do: struct!(%Orax{conn: nil, mode: :idle, timeout: 1000}, fields)

  test "status mismatches are reported to DBConnection without a round trip" do
    assert {:idle, _} = Orax.handle_commit([], state(mode: :idle))
    assert {:idle, _} = Orax.handle_rollback([], state(mode: :idle))
    assert {:idle, _} = Orax.handle_begin([mode: :savepoint], state(mode: :idle))
    assert {:transaction, _} = Orax.handle_begin([], state(mode: :transaction))
  end
end
