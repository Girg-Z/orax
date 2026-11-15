defmodule Orax.Integration do
  @moduledoc false
  # Real database tests are tagged :oracle and excluded by default.
  # Run them with `mix test --include oracle`; the connection is taken from
  # ORAX_TEST_{HOST,PORT,USER,PASSWORD,DATABASE} and defaults to the
  # local Oracle Free container (orax_test/OraxTest1@127.0.0.1:1521/FREEPDB1,
  # created by test/support/create_test_user.sql).

  def config(extra \\ []) do
    [
      hostname: System.get_env("ORAX_TEST_HOST", "127.0.0.1"),
      port: String.to_integer(System.get_env("ORAX_TEST_PORT", "1521")),
      username: System.get_env("ORAX_TEST_USER", "orax_test"),
      password: System.get_env("ORAX_TEST_PASSWORD", "OraxTest1"),
      database: System.get_env("ORAX_TEST_DATABASE", "FREEPDB1"),
      pool_size: 1,
      log: false
    ]
    |> Keyword.merge(extra)
  end

  # Runs fun with repo started outside the test supervisor (e.g. in on_exit)
  # and stops it before returning, so the next module can start it again.
  def with_repo(repo, fun) do
    {:ok, pid} = repo.start_link(config())

    try do
      fun.()
    after
      Supervisor.stop(pid)
    end
  end

  def drop_table(repo, table) do
    repo.query!(
      "BEGIN EXECUTE IMMEDIATE 'DROP TABLE #{table}'; " <>
        "EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;"
    )
  end
end

defmodule Orax.Integration.Repo do
  use Ecto.Repo, otp_app: :orax, adapter: Ecto.Adapters.Orax
end

defmodule Orax.Integration.OtherRepo do
  use Ecto.Repo, otp_app: :orax, adapter: Ecto.Adapters.Orax
end

defmodule Orax.Integration.SandboxRepo do
  use Ecto.Repo, otp_app: :orax, adapter: Ecto.Adapters.Orax
end
