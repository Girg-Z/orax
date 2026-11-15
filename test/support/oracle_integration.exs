defmodule Orax.Integration do
  @moduledoc false
  # Real database tests are tagged :oracle and excluded by default.
  # Run them with `mix test --include oracle`; the connection is taken from
  # ORAX_TEST_{HOST,PORT,USER,PASSWORD,DATABASE} and defaults to the
  # local Oracle Free container (orax_test/OraxTest1@127.0.0.1:1521/FREEPDB1,
  # created by test/support/create_test_user.sql).
  # ORAX_TEST_SSL=1 connects over TLS checking the server certificate against
  # the system CAs (e.g. Autonomous Database with TLS and no wallet).
  # ORAX_TEST_TTC_FIELD_VERSION lowers the TTC field version the driver asks
  # for (e.g. 12, the one of 19c), to test older message layouts on 26ai.

  def config(extra \\ []) do
    {extra_params, extra} = Keyword.pop(extra, :parameters, [])

    [
      hostname: System.get_env("ORAX_TEST_HOST", "127.0.0.1"),
      port: String.to_integer(System.get_env("ORAX_TEST_PORT", "1521")),
      username: System.get_env("ORAX_TEST_USER", "orax_test"),
      password: System.get_env("ORAX_TEST_PASSWORD", "OraxTest1"),
      database: System.get_env("ORAX_TEST_DATABASE", "FREEPDB1"),
      parameters: ssl_parameters() |> Keyword.merge(field_version_parameters()) |> Keyword.merge(extra_params),
      pool_size: 1,
      log: false
    ]
    |> Keyword.merge(extra)
  end

  defp field_version_parameters do
    case System.get_env("ORAX_TEST_TTC_FIELD_VERSION") do
      nil -> []
      version -> [ttc_field_version: String.to_integer(version)]
    end
  end

  defp ssl_parameters do
    if System.get_env("ORAX_TEST_SSL") in ["1", "true"] do
      host = System.get_env("ORAX_TEST_HOST", "127.0.0.1") |> String.to_charlist()

      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: host,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    else
      []
    end
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
