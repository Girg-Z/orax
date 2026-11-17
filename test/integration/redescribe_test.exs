defmodule Orax.Integration.RedescribeTest do
  # A cached query the server parses again (e.g. its cursor was invalidated
  # by another session) comes back with a new describe: the LOB columns must
  # still be fetched with the types they were defined as.
  use ExUnit.Case, async: false

  @moduletag :oracle

  alias Orax.Integration
  alias Orax.Integration.Repo

  defmodule Other do
    use Ecto.Repo, otp_app: :orax, adapter: Ecto.Adapters.Orax
  end

  @query "SELECT id, k, c, b FROM orax_it_redescribe WHERE id = :1 ORDER BY k"
  @row [1, "a", "hello clob", <<1, 2>>]

  setup_all do
    start_supervised!({Repo, Integration.config()})
    start_supervised!({Other, Integration.config()})
    Integration.drop_table(Repo, "orax_it_redescribe")
    Repo.query!("CREATE TABLE orax_it_redescribe (id NUMBER, k VARCHAR2(20), c CLOB, b BLOB)")
    Repo.query!("INSERT INTO orax_it_redescribe VALUES (1, 'a', 'hello clob', HEXTORAW('0102'))")

    on_exit(fn ->
      Integration.with_repo(Repo, fn -> Integration.drop_table(Repo, "orax_it_redescribe") end)
    end)

    :ok
  end

  # Invalidates the cursors of the queries on the table, from another session.
  defp invalidate(table), do: Other.query!("GRANT SELECT ON #{table} TO PUBLIC")

  test "CLOB and BLOB columns after the cursor is invalidated" do
    assert %{rows: [@row]} = Repo.query!(@query, [1])
    assert %{rows: [@row]} = Repo.query!(@query, [1])

    invalidate("orax_it_redescribe")
    assert %{rows: [@row]} = Repo.query!(@query, [1])
    assert %{rows: [@row]} = Repo.query!(@query, [1])
  end

  test "streamed CLOB and BLOB columns after the cursor is invalidated" do
    stream = fn ->
      {:ok, rows} =
        Repo.transaction(fn ->
          Ecto.Adapters.SQL.stream(Repo, @query, [1]) |> Enum.flat_map(& &1.rows)
        end)

      rows
    end

    assert stream.() == [@row]
    invalidate("orax_it_redescribe")
    assert stream.() == [@row]
  end

  test "a table changed by another session" do
    assert %{rows: [@row]} = Repo.query!(@query, [1])
    Other.query!("ALTER TABLE orax_it_redescribe ADD (z NUMBER)")
    assert %{rows: [@row]} = Repo.query!(@query, [1])
    Other.query!("ALTER TABLE orax_it_redescribe DROP (z)")
    assert %{rows: [@row]} = Repo.query!(@query, [1])
  end

  @tag skip: Integration.needs_ttc_23_4()
  test "JSON columns after the cursor is invalidated" do
    Integration.drop_table(Repo, "orax_it_redescribe_json")
    Repo.query!("CREATE TABLE orax_it_redescribe_json (id NUMBER, j JSON)")
    Repo.query!(~s|INSERT INTO orax_it_redescribe_json VALUES (1, JSON('{"a":1}'))|)

    try do
      query = "SELECT id, j FROM orax_it_redescribe_json WHERE id = :1"
      assert %{rows: [[1, %{"a" => 1}]]} = Repo.query!(query, [1])
      assert %{rows: [[1, %{"a" => 1}]]} = Repo.query!(query, [1])
      invalidate("orax_it_redescribe_json")
      assert %{rows: [[1, %{"a" => 1}]]} = Repo.query!(query, [1])
      assert %{rows: [[1, %{"a" => 1}]]} = Repo.query!(query, [1])
    after
      Integration.drop_table(Repo, "orax_it_redescribe_json")
    end
  end
end
