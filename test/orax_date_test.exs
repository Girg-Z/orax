defmodule OraxDateTest do
  use ExUnit.Case, async: true

  test ":date loads Oracle DATE values returned as NaiveDateTime" do
    assert Ecto.Type.adapter_load(Orax, :date, ~N[2026-03-04 00:00:00]) == {:ok, ~D[2026-03-04]}
    assert Ecto.Type.adapter_load(Orax, :date, ~N[2026-03-04 13:14:15]) == {:ok, ~D[2026-03-04]}
    assert Ecto.Type.adapter_load(Orax, :date, ~D[2026-03-04]) == {:ok, ~D[2026-03-04]}
    assert Ecto.Type.adapter_load(Orax, :date, nil) == {:ok, nil}
  end
end
