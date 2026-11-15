Code.require_file("support/oracle_integration.exs", __DIR__)

# Tests tagged :oracle need a real database, see Orax.Integration.
ExUnit.start(exclude: [:oracle])
