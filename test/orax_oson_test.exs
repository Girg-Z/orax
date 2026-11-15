defmodule OraxOsonTest do
  use ExUnit.Case, async: true

  # Images are built by hand after the layout python-oracledb reads:
  # magic, version, flags, header sizes, hash ids, name offsets, names, tree.
  @magic <<0xFF, ?J, ?Z>>

  defp scalar(node), do: @magic <> <<1, 0x00, 0x10, 0, 0>> <> node

  # Document with short field names. Names is a list of binaries, tree the
  # tree segment, flags the primary flags (uint16 field names segment).
  defp doc(names, tree, flags \\ 0, version \\ 1) do
    n = length(names)
    {offsets, seg, _} =
      Enum.reduce(names, {<<>>, <<>>, 0}, fn name, {o, s, pos} ->
        {o <> <<pos::16>>, s <> <<byte_size(name)>> <> name, pos + 1 + byte_size(name)}
      end)

    long = if version == 3, do: <<0x0100::16, 0::32, 0::32>>, else: <<>>

    @magic <>
      <<version, flags::16, n, byte_size(seg)::16>> <>
      long <>
      <<byte_size(tree)::16, 0::16>> <>
      :binary.copy(<<0>>, n) <> offsets <> seg <> tree
  end

  test "scalars" do
    assert :orax_oson.decode(scalar(<<0x30>>)) == nil
    assert :orax_oson.decode(scalar(<<0x31>>)) == true
    assert :orax_oson.decode(scalar(<<0x32>>)) == false
    assert :orax_oson.decode(scalar(<<0>>)) == ""
    assert :orax_oson.decode(scalar(<<3, "abc">>)) == "abc"
    assert :orax_oson.decode(scalar(<<0x33, 2, "é">>)) == "é"
    assert :orax_oson.decode(scalar(<<0x37, 300::16>> <> String.duplicate("x", 300))) ==
             String.duplicate("x", 300)
    assert :orax_oson.decode(scalar(<<0x38, 2::32, "hi">>)) == "hi"
  end

  test "numbers" do
    # integer with the length in the node (0x40), decimal (0x20), explicit length
    assert :orax_oson.decode(scalar(<<0x42, 0xC1, 0x02>>)) == 1
    assert :orax_oson.decode(scalar(<<0x42, 0xC1, 0x2B>>)) == 42
    assert :orax_oson.decode(scalar(<<0x21, 0xC1, 0x02>>)) == 1
    assert :orax_oson.decode(scalar(<<0x34, 3, 0xC1, 0x02, 0x33>>)) == 1.5
    assert :orax_oson.decode(scalar(<<0x41, 0x80>>)) == 0
  end

  test "binary floats, dates, intervals, binary, id" do
    # 1.5 as BINARY_DOUBLE: 3FF8000000000000 with the sign bit flipped
    assert :orax_oson.decode(scalar(<<0x36, 0xBF, 0xF8, 0, 0, 0, 0, 0, 0>>)) == 1.5
    assert :orax_oson.decode(scalar(<<0x7F, 0xBF, 0xC0, 0, 0>>)) == 1.5
    date = <<120, 124, 3, 15, 11, 31, 46>>
    assert :orax_oson.decode(scalar(<<0x3C>> <> date)) == {{2024, 3, 15}, {10, 30, 45}}
    assert :orax_oson.decode(scalar(<<0x7D>> <> date)) == {{2024, 3, 15}, {10, 30, 45}}
    assert :orax_oson.decode(scalar(<<0x39>> <> date <> <<0::32>>)) ==
             {{2024, 3, 15}, {10, 30, 45.0}}
    assert :orax_oson.decode(scalar(<<0x3A, 3::16, 1, 2, 3>>)) == <<1, 2, 3>>
    assert :orax_oson.decode(scalar(<<0x3B, 2::32, 1, 2>>)) == <<1, 2>>
    assert :orax_oson.decode(scalar(<<0x7E, 2, 9, 8>>)) == <<9, 8>>
    ds = <<0x80000001::32, 60, 60, 60, 0x80000000::32>>
    assert :orax_oson.decode(scalar(<<0x3E>> <> ds)) == :orax_values.interval(ds)
  end

  test "object with a short field name" do
    # object: 0x84, 1 child, field id 1, offset 5; then the number 1
    tree = <<0x84, 1, 1, 5::16, 0x42, 0xC1, 0x02>>
    assert :orax_oson.decode(doc(["a"], tree)) == %{"a" => 1}
  end

  test "nested objects and arrays" do
    # {"a": [1, "x", null], "b": {"a": true}}
    # root @0 (8 bytes), array @8 (8 bytes), its children @16, object after
    arr = <<0xC0, 3, 16::16, 19::16, 21::16>>
    kids = <<0x42, 0xC1, 0x02, 1, ?x, 0x30>>
    inner_at = 8 + byte_size(arr) + byte_size(kids)
    inner = <<0x84, 1, 1, inner_at + 5::16, 0x31>>
    tree = <<0x84, 2, 1, 2, 8::16, inner_at::16>> <> arr <> kids <> inner

    assert :orax_oson.decode(doc(["a", "b"], tree)) ==
             %{"a" => [1, "x", nil], "b" => %{"a" => true}}
  end

  test "empty containers" do
    assert :orax_oson.decode(doc([], <<0x84, 0>>)) == %{}
    assert :orax_oson.decode(doc([], <<0xC0, 0>>)) == []
  end

  test "array of scalars at the root, uint32 offsets and counts" do
    # 0xE0: array, 32-bit offsets (0x20), uint8 count
    tree = <<0xE0, 2, 10::32, 11::32, 0x31, 0x32>>
    assert :orax_oson.decode(doc([], tree)) == [true, false]
    # uint16 count (0x08)
    tree = <<0xC8, 2::16, 7::16, 8::16, 0x31, 0x32>>
    assert :orax_oson.decode(doc([], tree)) == [true, false]
    # uint32 count (0x10)
    tree = <<0xD0, 2::32, 9::16, 10::16, 0x31, 0x32>>
    assert :orax_oson.decode(doc([], tree)) == [true, false]
  end

  test "relative offsets" do
    # offsets are relative to the start of the container node: the array is
    # at 0 here, so the offsets are the same; nest it to tell them apart.
    # [[true]] with the inner array at 6
    tree = <<0xC0, 1, 4::16, 0xC0, 1, 4::16, 0x31>>
    # inner at 4 (relative to the outer at 0), true at +4 from the inner
    assert :orax_oson.decode(doc([], tree, 0x0001)) == [[true]]
  end

  test "shared field ids" do
    # {"a":1,"b":2} and an array of it with the second object sharing the field ids
    # first object @0 (u8 count), second @12 with 0x18: ids shared with the one at 0
    first = <<0x84, 2, 1, 2, 30::16, 33::16>>
    second = <<0x98, 0::16, 36::16, 39::16>>
    # layout: array @0: C0 n=2 off 6, 14 ; first @6 (8 bytes); second @14 (7 bytes)
    arr = <<0xC0, 2, 6::16, 14::16>>
    values = <<0x42, 0xC1, 0x02, 0x42, 0xC1, 0x03, 0x42, 0xC1, 0x04, 0x42, 0xC1, 0x05>>
    base = byte_size(arr <> first <> second)
    first = <<0x84, 2, 1, 2, base::16, base + 3::16>>
    second = <<0x98, 6::16, base + 6::16, base + 9::16>>
    tree = arr <> first <> second <> values

    assert :orax_oson.decode(doc(["a", "b"], tree)) ==
             [%{"a" => 1, "b" => 2}, %{"a" => 3, "b" => 4}]
  end

  test "uint32 field names segment and long field names" do
    long = String.duplicate("n", 300)
    # version 3: no short names, one long name; header after the short part:
    # secondary flags (uint16 offsets), num long, long seg size
    seg = <<300::16>> <> long
    tree = <<0x84, 1, 1, 5::16, 0x31>>

    img =
      @magic <>
        <<3, 0::16, 0, 0::16>> <>
        <<0x0100::16, 1::32, byte_size(seg)::32>> <>
        <<byte_size(tree)::16, 0::16>> <>
        <<0, 0>> <> <<0::16>> <> seg <> tree

    assert :orax_oson.decode(img) == %{long => true}

    # short and long names together, 32-bit offsets, uint32 sizes and counts
    short = <<1, ?s>>
    img =
      @magic <>
        <<3, (0x0800 + 0x1000 + 0x0008)::16, 1::32, byte_size(short)::32>> <>
        <<0::16, 1::32, byte_size(seg)::32>> <>
        <<byte_size(tree)::32, 0::16>> <>
        <<0>> <> <<0::32>> <> short <> <<0, 0>> <> <<0::32>> <> seg <>
        <<0x84, 2, 0, 0, 0, 1, 0, 0, 0, 2, 14::16, 15::16, 0x31, 0x32>>

    assert :orax_oson.decode(img) == %{"s" => true, long => false}
  end

  test "errors" do
    assert_raise ErlangError, fn -> :orax_oson.decode(<<1, 2, 3, 4>>) end
    assert catch_error(:orax_oson.decode(<<1, 2, 3, 4>>)) == {:oson, {:unexpected_data, <<1, 2, 3>>}}
    assert catch_error(:orax_oson.decode(@magic <> <<2, 0, 0x10>>)) ==
             {:oson, {:version_not_supported, 2}}
    assert {:oson, {:node_type_not_supported, 0x35}} == catch_error(:orax_oson.decode(scalar(<<0x35>>)))
    assert {:oson, {:invalid_field_id, 2}} ==
             catch_error(:orax_oson.decode(doc(["a"], <<0x84, 1, 2, 5::16, 0x31>>)))
  end
end
