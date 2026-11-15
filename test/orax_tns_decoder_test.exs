defmodule OraxTnsDecoderTest do
  use ExUnit.Case, async: true

  require Record

  Record.defrecordp :resp, Record.extract(:resp, from: "include/orax.hrl")
  Record.defrecordp :caps, Record.extract(:caps, from: "include/orax.hrl")
  Record.defrecordp :format, Record.extract(:format, from: "include/orax.hrl")

  @tti_rxh 6
  @tti_rxd 7
  @tti_rpa 8
  @tti_status 9
  @tti_bvc 21
  @tti_eor 29

  defp id_column, do: format(column_name: "ID", data_type: 2, data_length: 22, data_scale: 0)
  defp name_column, do: format(column_name: "NAME", data_type: 1, data_length: 40, csfrm: 1)

  defp fetch_resp(columns, eor \\ false) do
    resp(caps: caps(field_version: 24, server_field_version: 27, end_of_response: eor),
      msg: :execute, in_fetch: true, columns: columns, out: columns)
  end

  defp decode(data, resp), do: :orax_tns_decoder.decode_response(data, {<<>>, resp}, true)

  # flags, num requests, iteration number, num iters, buffer length, bit vector, rxhrid
  @row_header <<@tti_rxh, 0, 0, 0, 0, 0, 0, 0>>
  defp row(number), do: <<@tti_rxd, 2, 193, number + 1>>

  # end of call status, end to end sequence number
  defp status, do: <<@tti_status, 0, 0>>

  defp rows_response do
    <<@row_header::binary, row(1)::binary, @row_header::binary, row(2)::binary,
      @row_header::binary, row(3)::binary, status()::binary>>
  end

  defp rows(resp(rows: rows)), do: Enum.reverse(rows)

  # SELECT ... FOR UPDATE responses repeat the row header before every row.
  test "row headers between rows keep the rows already decoded" do
    assert {:ok, resp} = decode(rows_response(), fetch_resp([id_column()]))
    assert rows(resp) == [[1], [2], [3]]
  end

  test "columns left out by the bit vector repeat the previous row" do
    data =
      <<@tti_rxd, 2, 193, 2, 1, "a", @tti_bvc, 1, 1, 0b10, @tti_rxd, 1, "b",
        @tti_rxd, 2, 193, 3, 1, "c", status()::binary>>

    assert {:ok, resp} = decode(data, fetch_resp([id_column(), name_column()]))
    # the second row only sends NAME; the bit vector is not kept for the next row
    assert rows(resp) == [[1, "a"], [1, "b"], [2, "c"]]
  end

  describe "packets" do
    test "lengths take 16 bits before TNS 315 and 32 bits from it" do
      payload = <<0, 0, 9, 1>>

      assert {:ok, 6, 0, ^payload, "rest"} =
               :orax_tns_decoder.decode_packet(<<12::16, 0::16, 6, 0, 0::16, payload::binary, "rest">>, 313)

      assert {:ok, 6, 0, ^payload, "rest"} =
               :orax_tns_decoder.decode_packet(<<12::32, 6, 0, 0::16, payload::binary, "rest">>, 319)
    end

    test "a packet not received whole needs more data" do
      assert :more = :orax_tns_decoder.decode_packet(<<12::32, 6, 0>>, 319)
      assert :more = :orax_tns_decoder.decode_packet(<<12::32, 6, 0, 0::16, 0, 0>>, 319)
      assert {:error, {:packet_length, 3}} = :orax_tns_decoder.decode_packet(<<3::32, 6, 0, 0::16>>, 319)
    end
  end

  describe "resumable decoding" do
    test "a response split at any byte decodes as a whole one" do
      data = rows_response()
      {:ok, expected} = decode(data, fetch_resp([id_column()]))

      for split <- 0..byte_size(data) do
        <<first::binary-size(^split), second::binary>> = data
        cont = {<<>>, fetch_resp([id_column()])}

        result =
          case :orax_tns_decoder.decode_response(first, cont, false) do
            {:more, cont2} -> :orax_tns_decoder.decode_response(second, cont2, false)
            {:ok, result} when second == <<>> -> {:ok, result}
          end

        assert result == {:ok, expected}, "split at #{split}"
      end
    end

    test "only the message cut short is decoded again" do
      data = rows_response()
      # two row headers and rows (12 bytes each) and part of the third header
      first = binary_part(data, 0, 27)
      assert {:more, {pending, resp}} =
               :orax_tns_decoder.decode_response(first, {<<>>, fetch_resp([id_column()])}, false)

      assert rows(resp) == [[1], [2]]
      assert pending == binary_part(data, 24, 3)
    end

    test "a response cut short is an error once it is complete" do
      data = rows_response()
      first = binary_part(data, 0, byte_size(data) - 2)

      assert {:error, {:decode_error, details}} = decode(first, fetch_resp([id_column()]))
      assert details[:message_type] == @tti_status
      assert details[:reason] == "incomplete_message"
    end

    test "an unknown message type is an error" do
      assert {:error, {:decode_error, details}} =
               :orax_tns_decoder.decode_response(<<0xEE, 1, 2, 3>>, {<<>>, fetch_resp([])}, false)

      assert details[:message_type] == 0xEE
      assert details[:reason] =~ "unknown_message_type"
    end
  end

  describe "end of response" do
    test "without the marker the status ends the response" do
      assert {:ok, resp(end_of_response: true)} =
               :orax_tns_decoder.decode_response(status(), {<<>>, fetch_resp([])}, false)
    end

    test "with the marker the response goes on to it" do
      assert {:more, _} = :orax_tns_decoder.decode_response(status(), {<<>>, fetch_resp([], true)}, false)

      assert {:ok, resp(end_of_response: true, call_ended: true)} =
               :orax_tns_decoder.decode_response(<<status()::binary, @tti_eor>>, {<<>>, fetch_resp([], true)}, false)
    end
  end

  # Error info of a 26ai server (field version 27): the extended error number
  # and row count, then the sql type and server checksum of 20.1.
  test "error info gives the error number, message and cursor" do
    message = "ORA-00942: table or view does not exist\n"

    data =
      <<4, 1, 1, 0, 0, 2, 3, 174, 0, 0, 1, 7, 0, 0::40, 0, 0::40, 0, 0, 3, 0, 0, 0, 0, 0, 0,
        2, 3, 174, 0, 0, 0, byte_size(message), message::binary>>

    assert {:ok, resp(error_num: 942, cursor_id: 7, error_message: msg, end_of_response: true)} =
             decode(data, fetch_resp([]))

    assert msg == message
  end

  test "return parameters skip chunked keyword values" do
    assert {:ok, _} = decode(return_parameters(<<0>>, chunked_field()), fetch_resp([]))
  end

  test "return parameters skip chunked keywords" do
    assert {:ok, _} = decode(return_parameters(chunked_field(), <<0>>), fetch_resp([]))
  end

  defp chunked_field do
    # chunks of ub4 length and bytes, up to a zero length
    first_chunk = :binary.copy(<<0xAA>>, 64)
    encoded_value = <<254, 1, 64, first_chunk::binary, 1, 1, 0xBB, 0>>
    <<1, 65, encoded_value::binary>>
  end

  defp return_parameters(keyword, value) do
    <<
      @tti_rpa,
      # no array parameters
      0,
      # no text value
      0,
      # one keyword/value pair
      1,
      1,
      keyword::binary,
      value::binary,
      # keyword number
      0,
      # no registration info
      0,
      status()::binary
    >>
  end

  # protocol response of Oracle AI Database 26ai Free 23.26.3
  @pro_26ai Base.decode16!(
              "0106007838365F36342F4C696E757820322E342E7878006903010A006603400301400366030166034803014803660301660352030152036603016603610301610366030166031F03081F0366030100640000006001240F050B0C030C0C0504050D0609070805050505050F05050505050A050505050504050607080823472347081123081141B0470083036907D003000000000000000000000000000000000000000000000000000000000000000000000000003706010101EF0F011B010101010101017FFF031003030101FF01FFFF010E0101FF01060CF6097F050FFF0D0B00FF030000000000070202040D0201000118007F010200000000"
            )

  test "the protocol response gives the server capabilities" do
    assert {:ok, resp(server_caps: {compile_caps, runtime_caps})} =
             decode(@pro_26ai, resp(msg: :protocol))

    assert byte_size(compile_caps) == 55
    assert :binary.at(compile_caps, 7) == 27
    assert runtime_caps == <<2, 1, 0, 1, 24, 0, 127, 1, 2, 0, 0, 0, 0>>
  end

  test "a protocol response cut short is incomplete" do
    short = binary_part(@pro_26ai, 0, byte_size(@pro_26ai) - 20)
    assert {:more, _} = :orax_tns_decoder.decode_response(short, {<<>>, resp(msg: :protocol)}, false)
  end
end
