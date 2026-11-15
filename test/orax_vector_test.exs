defmodule OraxVectorTest do
  use ExUnit.Case, async: true

  @z8 <<0::64>>

  test "float32 round trip" do
    v = {:float32, [1.5, -2.25, 0.0, 1.0e10]}
    assert :orax_vector.decode(:orax_vector.encode(v)) == v
  end

  test "float64 round trip" do
    v = {:float64, [1.1, -2.2, 0.0, 1.0e300]}
    assert :orax_vector.decode(:orax_vector.encode(v)) == v
  end

  test "int8 round trip" do
    v = {:int8, [-128, -1, 0, 1, 127]}
    assert :orax_vector.decode(:orax_vector.encode(v)) == v
  end

  test "binary round trip" do
    v = {:binary, <<0xA5, 0x01, 0xFF>>}
    assert :orax_vector.decode(:orax_vector.encode(v)) == v
  end

  test "sparse round trips" do
    for {f, vals} <- [float32: [1.5, -3.0], float64: [2.5, -0.125], int8: [-5, 7]] do
      v = {:sparse, f, 100, [3, 99], vals}
      assert :orax_vector.decode(:orax_vector.encode(v)) == v
    end

    v = {:sparse, :int8, 10, [], []}
    assert :orax_vector.decode(:orax_vector.encode(v)) == v
  end

  test "nan and infinities" do
    for f <- [:float32, :float64] do
      v = {f, [:nan, :infinity, :"-infinity", 1.0]}
      assert :orax_vector.decode(:orax_vector.encode(v)) == v
    end
  end

  test "float32 image byte for byte" do
    # magic, version 0, flags NORM_RESERVED|NORM = 0x12, format 2, 2 dims,
    # norm reserved; 1.0 = 3F800000 -> BF800000, -2.0 = C0000000 -> 3FFFFFFF
    assert :orax_vector.encode({:float32, [1.0, -2.0]}) ==
             <<0xDB, 0, 0x00, 0x12, 2, 0, 0, 0, 2>> <>
               @z8 <> <<0xBF, 0x80, 0, 0, 0x3F, 0xFF, 0xFF, 0xFF>>
  end

  test "float64 image byte for byte" do
    # 1.0 = 3FF0000000000000 -> BFF0000000000000
    assert :orax_vector.encode({:float64, [1.0]}) ==
             <<0xDB, 0, 0x00, 0x12, 3, 0, 0, 0, 1>> <>
               @z8 <> <<0xBF, 0xF0, 0, 0, 0, 0, 0, 0>>
  end

  test "int8 image byte for byte" do
    assert :orax_vector.encode({:int8, [-1, 2]}) ==
             <<0xDB, 0, 0x00, 0x12, 4, 0, 0, 0, 2>> <> @z8 <> <<0xFF, 2>>
  end

  test "binary image: version 1, no norm flag, dims = 8 * bytes" do
    assert :orax_vector.encode({:binary, <<0xAB, 0xCD>>}) ==
             <<0xDB, 1, 0x00, 0x10, 5, 0, 0, 0, 16>> <> @z8 <> <<0xAB, 0xCD>>
  end

  test "sparse image: version 2, flags 0x32" do
    assert :orax_vector.encode({:sparse, :int8, 50, [4, 7], [-1, 2]}) ==
             <<0xDB, 2, 0x00, 0x32, 4, 0, 0, 0, 50>> <>
               @z8 <> <<0, 2, 0, 0, 0, 4, 0, 0, 0, 7, 0xFF, 2>>
  end

  test "decode skips the norm only when flagged" do
    # no norm flags: values follow the header directly
    assert :orax_vector.decode(<<0xDB, 0, 0, 0, 4, 0, 0, 0, 2, 1, 0xFE>>) ==
             {:int8, [1, -2]}

    # norm flag: 8 bytes with arbitrary content are skipped
    assert :orax_vector.decode(
             <<0xDB, 0, 0, 2, 4, 0, 0, 0, 1>> <> <<9, 9, 9, 9, 9, 9, 9, 9, 5>>
           ) == {:int8, [5]}
  end

  test "errors" do
    assert_raise ErlangError, fn -> :orax_vector.decode(<<0xAA, 0, 0, 0, 4, 0, 0, 0, 0>>) end

    assert catch_error(:orax_vector.decode(<<0xAA, 0, 0, 0, 4, 0, 0, 0, 0>>)) ==
             {:vector, {:unexpected_data, 0xAA}}

    assert catch_error(:orax_vector.decode(<<0xDB, 3, 0, 0, 4, 0, 0, 0, 0>>)) ==
             {:vector, {:version_not_supported, 3}}

    assert catch_error(:orax_vector.decode(<<0xDB, 0, 0, 0, 9, 0, 0, 0, 0>>)) ==
             {:vector, {:format_not_supported, 9}}

    assert {:vector, _} = catch_error(:orax_vector.encode({:sparse, :binary, 8, [1], [1]}))
  end
end
