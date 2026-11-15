defmodule Orax.Ecto.Vector do
  @moduledoc """
  The Ecto type of `VECTOR` fields, holding `Orax.Vector` values.

      schema "docs" do
        field :embedding, Orax.Ecto.Vector
      end

  A list of numbers casts (and dumps) to a dense `:float32` vector. In migrations the
  column type is the Oracle one, e.g. `add :embedding, :"vector(1536, float32)"`.
  """

  use Ecto.Type

  @impl true
  def type, do: :vector

  @impl true
  def cast(%Orax.Vector{} = vector), do: {:ok, vector}

  def cast(values) when is_list(values) do
    {:ok, Orax.Vector.new(values)}
  rescue
    ArgumentError -> :error
  end

  def cast(_value), do: :error

  @impl true
  def load(%Orax.Vector{} = vector), do: {:ok, vector}
  def load(_value), do: :error

  @impl true
  def dump(%Orax.Vector{} = vector), do: {:ok, vector}
  def dump(values) when is_list(values), do: cast(values)
  def dump(_value), do: :error
end
