defmodule OraxTnsEncoderTest do
  use ExUnit.Case, async: true

  require Record

  Record.defrecordp :oraclient, Record.extract(:oraclient, from: "include/orax.hrl")
  Record.defrecordp :caps, Record.extract(:caps, from: "include/orax.hrl")
  Record.defrecordp :exec, Record.extract(:exec, from: "include/orax.hrl")
  Record.defrecordp :format, Record.extract(:format, from: "include/orax.hrl")

  @varchar 1
  @number 2
  @raw 23
  @rxd 7

  defp bind_format(value), do: :orax_tns_encoder.bind_format(value, [value])

  defp encode_exec(kind, binds, rows, opts \\ []) do
    all = [binds | rows]

    formats =
      binds
      |> Enum.with_index()
      |> Enum.map(fn {b, i} -> :orax_tns_encoder.bind_format(b, Enum.map(all, &Enum.at(&1, i))) end)

    record =
      oraclient(seq: 1, caps: caps(field_version: Keyword.get(opts, :field_version, 24), max_string_size: 32767),
        req: exec(sql: "SQL", kind: kind, binds: formats, rows: [binds | rows]))

    {:orax_tns_encoder.encode_record(:exec, record), formats}
  end

  # The row data of the given rows, values in the given order.
  defp rxd(formats_and_rows) do
    for row <- formats_and_rows, into: <<>> do
      <<@rxd, (for {f, v} <- row, into: <<>>, do: :orax_tns_encoder.value_bytes(f, v))::binary>>
    end
  end

  describe "bind metadata" do
    test "strings are VARCHAR with 4 bytes per byte of the longest value" do
      assert format(data_type: @varchar, data_length: 12, csfrm: 1) = bind_format(~c"abc")
      assert format(data_length: 20) = :orax_tns_encoder.bind_format(~c"a", [~c"a", ~c"hello"])
    end

    test "binaries are text, {:raw, bytes} RAW of their length, numbers NUMBER" do
      assert format(data_type: @varchar, max_size: 3) = bind_format("abc")
      assert format(data_type: @raw, data_length: 5000) = bind_format({:raw, :binary.copy(<<1>>, 5000)})
      assert format(data_type: @raw, data_length: 4000) = bind_format({:raw, <<>>})
      assert format(data_type: @number, data_length: 22) = bind_format(42)
    end

    test "null takes the type of the first value of the rows that is not null" do
      assert format(data_type: @number) = :orax_tns_encoder.bind_format(:null, [:null, 1])
      assert format(data_type: @raw) = :orax_tns_encoder.bind_format(:null, [:null, {:raw, <<1>>}])
      assert format(data_type: @varchar, data_length: 4) = :orax_tns_encoder.bind_format(:null, [:null])
    end

    test "out binds take the type asked for" do
      assert format(param: :out, data_type: @varchar, data_length: 4000) = bind_format({:out, :varchar})
      assert format(param: :out, data_type: @number) = bind_format({:out, :integer})
    end
  end

  describe "bind values" do
    # The bytes python-oracledb 26.1 sends for array.array("f", [1.5, 2.0, -3.25]):
    # the value based QLocator, then the VECTOR image.
    test "a vector is a QLocator and its image, as python-oracledb sends it" do
      vector = {:float32, [1.5, 2.0, -3.25]}
      assert format(data_type: 127, data_length: 1_048_576) = bind_format(vector)

      assert :orax_tns_encoder.value_bytes(bind_format(vector), vector) ==
               Base.decode16!(
                 "01282800260004610800000001000000000000001D00000000000000000000000000000000" <>
                   "0000000000001DDB00001202000000030000000000000000BFC00000C00000003FAFFFFF"
               )
    end

    test "values up to 252 bytes follow their length, longer ones go in chunks" do
      assert :orax_tns_encoder.value_bytes(bind_format(~c"ab"), ~c"ab") == <<2, "ab">>
      long = :binary.copy(<<1>>, 40000)

      assert :orax_tns_encoder.value_bytes(bind_format(long), long) ==
               <<254, 2, 0x7F, 0xFF, :binary.part(long, 0, 32767)::binary, 2, 0x1C, 0x41,
                 :binary.part(long, 32767, 7233)::binary, 0>>
    end

    test "nulls and out binds are sent as null" do
      assert :orax_tns_encoder.value_bytes(bind_format(:null), :null) == <<0>>
      assert :orax_tns_encoder.value_bytes(bind_format({:out, :varchar}), :null) == <<0>>
    end
  end

  describe "execute" do
    test "values of long binds go after the other values of a SQL row" do
      long = :binary.copy(<<1>>, 40000)
      {data, [fl, fn_, fs]} = encode_exec(:dml, [long, 42, ~c"abc"], [])

      assert String.ends_with?(data, rxd([[{fn_, 42}, {fs, ~c"abc"}, {fl, long}]]))
    end

    test "rows without long binds keep their order" do
      raw = :crypto.strong_rand_bytes(32)
      {data, [fr, fn_]} = encode_exec(:query, [raw, 42], [])

      assert String.ends_with?(data, rxd([[{fr, raw}, {fn_, 42}]]))
    end

    test "PL/SQL blocks keep long binds in place" do
      long = :binary.copy(<<1>>, 40000)
      {data, [fl, fn_]} = encode_exec(:plsql, [long, 42], [])

      assert String.ends_with?(data, rxd([[{fl, long}, {fn_, 42}]]))
    end

    test "batch rows are reordered like the first row" do
      long = :binary.copy(<<1>>, 40000)
      {data, [fl, fn_]} = encode_exec(:dml, [long, 1], [[long, 2]])

      assert String.ends_with?(data, rxd([[{fn_, 1}, {fl, long}], [{fn_, 2}, {fl, long}]]))
    end

    test "the function header carries the token number from field version 23.1 ext 1 on" do
      {data, _} = encode_exec(:query, [], [], field_version: 24)
      assert <<3, 94, 1, 0, _::binary>> = data

      {data, _} = encode_exec(:query, [], [], field_version: 12)
      assert <<3, 94, 1, options, _::binary>> = data
      assert options != 0
    end
  end

  defp login(desc), do: :orax_tns_encoder.encode_record(:login, oraclient(sdu: 8192, auth: desc))

  test "connect data up to 230 bytes stays in the connect packet" do
    desc = ~c"(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=" ++ List.duplicate(?a, 230 - 44) ++ ~c")))"
    assert length(desc) == 230

    {connect, rest} = login(desc)
    assert rest == <<>>
    assert <<_::binary-size(16), 230::16, 74::16, _::binary>> = connect
    assert byte_size(connect) == 74 - 8 + 230
    assert String.ends_with?(connect, List.to_string(desc))
  end

  test "connect data over 230 bytes goes in a data packet after the connect packet" do
    desc = ~c"(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=" ++ List.duplicate(?a, 231 - 44) ++ ~c")))"
    assert length(desc) == 231

    {connect, data} = login(desc)
    assert data == List.to_string(desc)
    # the header still declares the whole connect data length and its offset
    assert <<_::binary-size(16), 231::16, 74::16, _::binary>> = connect
    assert byte_size(connect) == 74 - 8
  end

  defp dty(record) do
    <<2, 873::little-16, 873::little-16, 3, length, caps::binary-size(length), rest::binary>> =
      :orax_tns_encoder.encode_record(:dty, record)

    <<runtime_length, _runtime::binary-size(runtime_length), table::binary>> = rest
    {caps, table}
  end

  test "compile caps carry the field version, ub2 data types and end of response if offered" do
    {caps, _} = dty(oraclient(charset: 873, caps: caps(field_version: 24), eor: false))
    assert byte_size(caps) == 55
    assert :binary.at(caps, 7) == 24
    assert :binary.at(caps, 27) == 1
    assert :binary.at(caps, 40) == 0

    {caps, _} = dty(oraclient(charset: 873, caps: caps(field_version: 12), eor: :offered))
    assert :binary.at(caps, 7) == 12
    assert :binary.at(caps, 40) == 0x20
  end

  test "the data types table is sent as ub2 entries ending with a zero type" do
    {_, table} = dty(oraclient(charset: 873, caps: caps(field_version: 24), eor: false))
    assert byte_size(table) == 322 * 8 + 2
    assert <<1::16, 1::16, 1::16, 0::16, 2::16, 2::16, 10::16, 0::16, _::binary>> = table
    assert binary_part(table, byte_size(table) - 2, 2) == <<0, 0>>
    # VECTOR is negotiated as itself
    assert :binary.match(table, <<127::16, 127::16, 1::16, 0::16>>) != :nomatch
  end
end
