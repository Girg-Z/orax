defmodule OraxTnsEncoderTest do
  use ExUnit.Case, async: true

  require Record

  Record.defrecordp :oraclient,
    Record.extract(:oraclient, from: "include/orax.hrl")
  Record.defrecordp :format,
    Record.extract(:format, from: "include/orax.hrl")

  @raw 23
  @long_raw 24

  defp oac_type(value) do
    <<type, _rest::binary>> = :orax_tns_encoder.encode_token(:oac, value, format(charset: 871))
    type
  end

  defp exec(type, binds) do
    record =
      oraclient(type: type, auto: 1, charset: 871, fetch: 10, seq: 1,
        req: {0, ~c"SELECT 1 FROM dual", binds, [], []})

    :orax_tns_encoder.encode_record(:exec, record)
  end

  # Encoded row data (TTI_RXD + values) for the given rows, in the given order.
  defp rxd(rows), do: :orax_tns_encoder.encode_token(:rxd, rows, <<>>)

  test "binary binds up to 4000 bytes are RAW, larger ones LONG RAW" do
    assert oac_type(<<1>>) == @raw
    assert oac_type(:binary.copy(<<1>>, 4000)) == @raw
    assert oac_type(:binary.copy(<<1>>, 4001)) == @long_raw
  end

  test "values of long binds go after the other values of a SQL row" do
    long = :binary.copy(<<1>>, 5000)
    data = exec(:change, [long, 42, ~c"abc"])

    assert String.ends_with?(data, rxd([[42, ~c"abc", long]]))
  end

  test "rows without long binds keep their order" do
    raw = :crypto.strong_rand_bytes(32)
    data = exec(:select, [raw, 42])

    assert String.ends_with?(data, rxd([[raw, 42]]))
  end

  test "PL/SQL blocks keep long binds in place" do
    long = :binary.copy(<<1>>, 5000)
    data = exec(:block, [long, 42])

    assert String.ends_with?(data, rxd([[long, 42]]))
  end

  test "batch rows are reordered like the first row" do
    long = :binary.copy(<<1>>, 5000)
    record =
      oraclient(type: :change, auto: 1, charset: 871, fetch: 10, seq: 1,
        req: {0, ~c"INSERT INTO t VALUES (:1, :2)", [long, 1], [[long, 2]], []})

    data = :orax_tns_encoder.encode_record(:exec, record)

    assert String.ends_with?(data, rxd([[1, long], [2, long]]))
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

  # compile time capabilities as sent before they were built by a function
  @caps_11_2 <<38, 6, 1, 0, 0, 106, 1, 1, 6, 1, 1, 1, 1, 1, 1, 0, 41, 144, 3, 7, 3, 0, 1, 0,
               79, 1, 55, 4, 0, 0, 0, 0, 12, 0, 0, 6, 0, 1, 1>>
  @caps_11_2_eor <<41, 6, 1, 0, 0, 106, 1, 1, 6, 1, 1, 1, 1, 1, 1, 0, 41, 144, 3, 7, 3, 0, 1, 0,
                   79, 1, 55, 4, 0, 0, 0, 0, 12, 0, 0, 6, 0, 1, 1, 0, 0, 0x20>>

  defp dty_caps(record) do
    <<2, _charsets::binary-size(4), 1, length, caps::binary-size(length), _::binary>> =
      :orax_tns_encoder.encode_record(:dty, record)

    <<length, caps::binary>>
  end

  test "field version 6 compile caps are unchanged, with and without end of response" do
    assert dty_caps(oraclient(charset: 873, field_version: 6, eor: false)) == @caps_11_2
    assert dty_caps(oraclient(charset: 873, field_version: 6, eor: :offered)) == @caps_11_2_eor
  end
end
