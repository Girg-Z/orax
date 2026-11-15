defmodule Orax.Vector do
  @moduledoc """
  A value of the Oracle `VECTOR` type (Oracle Database 23.4 and later).

  A dense vector holds all its values: `:float32`, `:float64` and `:int8`
  vectors hold a list of numbers, `:binary` vectors a binary of 8 dimensions
  per byte. A sparse vector holds its number of dimensions and the indices
  (from 0) and values of the dimensions that are not zero.

      iex> Orax.Vector.new([1.5, 2.0, -3.25])
      %Orax.Vector{format: :float32, dimensions: 3, indices: nil, values: [1.5, 2.0, -3.25]}

      iex> Orax.Vector.sparse(10, [1, 7], [0.5, -1.0]) |> Orax.Vector.to_list()
      [0, 0.5, 0, 0, 0, 0, 0, -1.0, 0, 0]

  Vectors are bound and fetched as such, in both directions:

      Repo.query!("INSERT INTO docs (id, embedding) VALUES (:1, :2)",
        [1, Orax.Vector.new(embedding)])

  `Orax.Ecto.Vector` is the Ecto type of vector fields. Float values that
  Elixir cannot hold (NaN and the infinities) are the atoms `:nan`,
  `:infinity` and `:"-infinity"`.
  """

  @type format :: :float32 | :float64 | :int8 | :binary
  @type value :: number() | :nan | :infinity | :"-infinity"
  @type t :: %__MODULE__{
          format: format(),
          dimensions: non_neg_integer(),
          indices: [non_neg_integer()] | nil,
          values: [value()] | binary()
        }

  defstruct format: :float32, dimensions: 0, indices: nil, values: []

  @number_formats [:float32, :float64, :int8]

  @doc """
  A dense vector of the given values: a list of numbers for `:float32` (the
  default), `:float64` and `:int8`, a binary for `:binary`.
  """
  @spec new([value()] | binary(), format()) :: t()
  def new(values, format \\ :float32)

  def new(values, :binary) when is_binary(values),
    do: %__MODULE__{format: :binary, dimensions: byte_size(values) * 8, values: values}

  def new(values, format) when format in @number_formats and is_list(values) do
    Enum.each(values, &check_value!(&1, format))
    %__MODULE__{format: format, dimensions: length(values), values: values}
  end

  def new(values, format) do
    raise ArgumentError, "invalid #{inspect(format)} vector values: #{inspect(values)}"
  end

  @doc """
  A sparse vector of the given number of dimensions, with the values at the
  given indices (from 0) and zero elsewhere. Binary vectors cannot be sparse.
  """
  @spec sparse(non_neg_integer(), [non_neg_integer()], [value()], format()) :: t()
  def sparse(dimensions, indices, values, format \\ :float32)
      when is_integer(dimensions) and dimensions >= 0 and is_list(indices) and is_list(values) and
             format in @number_formats do
    if length(indices) != length(values) do
      raise ArgumentError, "a sparse vector needs as many indices as values"
    end

    Enum.each(indices, fn
      index when is_integer(index) and index >= 0 and index < dimensions -> :ok
      index -> raise ArgumentError, "invalid index #{inspect(index)} of a vector of #{dimensions} dimensions"
    end)

    Enum.each(values, &check_value!(&1, format))
    %__MODULE__{format: format, dimensions: dimensions, indices: indices, values: values}
  end

  @doc """
  Whether the vector is sparse.
  """
  @spec sparse?(t()) :: boolean()
  def sparse?(%__MODULE__{indices: indices}), do: indices != nil

  @doc """
  The values of all the dimensions; for a `:binary` vector, its bytes.
  """
  @spec to_list(t()) :: [value()] | [byte()]
  def to_list(%__MODULE__{format: :binary, values: values}), do: :binary.bin_to_list(values)
  def to_list(%__MODULE__{indices: nil, values: values}), do: values

  def to_list(%__MODULE__{dimensions: dimensions, indices: indices, values: values}) do
    set = Map.new(Enum.zip(indices, values))
    for i <- 0..(dimensions - 1)//1, do: Map.get(set, i, 0)
  end

  defp check_value!(value, :int8) when is_integer(value) and value in -128..127, do: :ok
  defp check_value!(value, format) when format != :int8 and is_number(value), do: :ok
  defp check_value!(value, format) when format != :int8 and value in [:nan, :infinity, :"-infinity"], do: :ok
  defp check_value!(value, format),
    do: raise(ArgumentError, "invalid #{inspect(format)} vector value: #{inspect(value)}")

  # The representation of the Erlang driver (orax_vector).
  @doc false
  def to_driver(%__MODULE__{format: :binary, values: values}), do: {:binary, values}
  def to_driver(%__MODULE__{format: format, indices: nil, values: values}), do: {format, values}

  def to_driver(%__MODULE__{format: format, dimensions: dimensions, indices: indices, values: values}),
    do: {:sparse, format, dimensions, indices, values}

  @doc false
  def from_driver({:binary, values}), do: new(values, :binary)

  def from_driver({format, values}) when format in @number_formats,
    do: %__MODULE__{format: format, dimensions: length(values), values: values}

  def from_driver({:sparse, format, dimensions, indices, values}),
    do: %__MODULE__{format: format, dimensions: dimensions, indices: indices, values: values}
end
