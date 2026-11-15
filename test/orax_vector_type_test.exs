defmodule Orax.VectorTypeTest do
  use ExUnit.Case, async: true

  doctest Orax.Vector

  alias Orax.Vector

  test "dense vectors of each format" do
    assert %Vector{format: :float64, dimensions: 2} = Vector.new([1.0, :nan], :float64)
    assert %Vector{format: :int8, dimensions: 3} = Vector.new([1, -128, 127], :int8)
    assert %Vector{format: :binary, dimensions: 16} = Vector.new(<<0xF0, 0x0F>>, :binary)
    assert Vector.to_list(Vector.new(<<0xF0, 0x0F>>, :binary)) == [0xF0, 0x0F]
    refute Vector.sparse?(Vector.new([1.0]))
  end

  test "values that do not fit the format are refused" do
    assert_raise ArgumentError, fn -> Vector.new([128], :int8) end
    assert_raise ArgumentError, fn -> Vector.new([1.5], :int8) end
    assert_raise ArgumentError, fn -> Vector.new(["a"]) end
    assert_raise ArgumentError, fn -> Vector.new([1.0], :float16) end
    assert_raise ArgumentError, fn -> Vector.sparse(3, [3], [1.0]) end
    assert_raise ArgumentError, fn -> Vector.sparse(3, [0, 1], [1.0]) end
  end

  test "the driver representation round trips" do
    for vector <- [Vector.new([1.5, 2.0]), Vector.new([1, 2], :int8), Vector.new(<<1>>, :binary),
                   Vector.sparse(10, [1, 7], [0.5, -1.0], :float64)] do
      assert vector |> Vector.to_driver() |> Vector.from_driver() == vector
    end

    assert Vector.to_driver(Vector.sparse(10, [1], [2.0])) == {:sparse, :float32, 10, [1], [2.0]}
  end

  test "binds and results of Orax.Query" do
    query = %Orax.Query{statement: "SELECT :1 FROM dual"}
    vector = Vector.new([1.0, 2.0])
    assert DBConnection.Query.encode(query, [vector], []) == [{:float32, [1.0, 2.0]}]

    assert %{rows: [[^vector, nil]]} =
             DBConnection.Query.decode(query, %{rows: [[{:float32, [1.0, 2.0]}, :null]]}, [])
  end

  test "the Ecto type casts lists and keeps vectors" do
    assert {:ok, %Vector{format: :float32, values: [1, 2.5]}} = Ecto.Type.cast(Orax.Ecto.Vector, [1, 2.5])
    assert :error = Ecto.Type.cast(Orax.Ecto.Vector, ["x"])
    assert :error = Ecto.Type.cast(Orax.Ecto.Vector, "x")
    vector = Vector.new([1.0])
    assert {:ok, ^vector} = Ecto.Type.dump(Orax.Ecto.Vector, vector)
    assert {:ok, ^vector} = Ecto.Type.load(Orax.Ecto.Vector, vector)
    assert {:ok, nil} = Ecto.Type.load(Orax.Ecto.Vector, nil)
  end
end
