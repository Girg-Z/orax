defmodule Orax.Integration.MigrationTest do
  use ExUnit.Case, async: false

  @moduletag :oracle

  alias Ecto.Adapters.Orax.Connection
  alias Ecto.Migration.{Constraint, Index, Table}
  alias Orax.Integration
  alias Orax.Integration.Repo

  @table "orax_it_mposts"

  defmodule CreatePosts do
    use Ecto.Migration

    def change do
      create table(:orax_it_mposts) do
        add :title, :string
      end
    end
  end

  # More than one change, with quoted defaults (a boolean is a char '0'/'1').
  defmodule AlterPosts do
    use Ecto.Migration

    def change do
      alter table(:orax_it_mposts) do
        add :published, :boolean, default: false, null: false
        add :status, :string, size: 20, default: "it's draft"
        modify :title, :string, size: 200, from: {:string, size: 2000}
      end
    end
  end

  setup_all do
    start_supervised!({Repo, Integration.config()})
    :ok
  end

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    Integration.drop_table(Repo, @table)
    Integration.drop_table(Repo, "schema_migrations")
  end

  defp ddl(command) do
    for statement <- Connection.execute_ddl(command),
        do: Repo.query!(IO.iodata_to_binary(statement))
  end

  defp columns do
    Repo.query!(
      "SELECT column_name, data_type, data_length, nullable, data_default " <>
        "FROM user_tab_columns WHERE table_name = :1 ORDER BY column_id",
      [String.upcase(@table)]
    ).rows
    |> Enum.map(fn [name, type, length, nullable, default] ->
      {String.downcase(name), type, length, nullable, default && String.trim(default)}
    end)
  end

  test "an alter with several changes runs forward and backward" do
    assert :ok = Ecto.Migrator.up(Repo, 1, CreatePosts, log: false)
    assert :ok = Ecto.Migrator.up(Repo, 2, AlterPosts, log: false)

    assert [
             {"id", "NUMBER", _, "N", _},
             {"title", "VARCHAR2", 200, "Y", nil},
             {"published", "CHAR", 1, "N", "'0'"},
             {"status", "VARCHAR2", 20, "Y", "'it''s draft'"}
           ] = columns()

    Repo.query!("INSERT INTO #{@table} (title) VALUES ('first')")

    assert %{rows: [["first", "0", "it's draft"]]} =
             Repo.query!("SELECT title, published, status FROM #{@table}")

    assert :ok = Ecto.Migrator.down(Repo, 2, AlterPosts, log: false)
    assert [{"id", _, _, _, _}, {"title", "VARCHAR2", 2000, "Y", nil}] = columns()
  end

  test "if_not_exists and if_exists ignore only the object being there or not" do
    table = %Table{name: :orax_it_mposts}
    columns = [{:add, :id, :bigserial, [primary_key: true]}, {:add, :status, :string, [default: "it's new"]}]
    index = %Index{table: :orax_it_mposts, name: :orax_it_mposts_status_index, columns: [:status]}
    constraint = %Constraint{table: :orax_it_mposts, name: :orax_it_mposts_status_known, check: "status IN ('it''s new', 'done')"}

    for _ <- 1..2 do
      ddl({:create_if_not_exists, table, columns})
      ddl({:create_if_not_exists, index})
      ddl({:create_if_not_exists, constraint})
    end

    Repo.query!("INSERT INTO #{@table} (id) VALUES (1)")
    assert %{rows: [["it's new"]]} = Repo.query!("SELECT status FROM #{@table}")

    assert_raise DBConnection.ConnectionError, ~r/ORA-02290/, fn ->
      Repo.query!("INSERT INTO #{@table} (id, status) VALUES (2, 'other')")
    end

    for drop <- [constraint, index, table], _ <- 1..2 do
      ddl({:drop_if_exists, drop, :restrict})
    end

    assert columns() == []
  end

  test "if_not_exists raises the errors that are not about the object being there" do
    table = %Table{name: :orax_it_mposts}

    assert_raise DBConnection.ConnectionError, ~r/ORA-00902/, fn ->
      ddl({:create_if_not_exists, table, [{:add, :status, :no_such_type, []}]})
    end
  end
end
