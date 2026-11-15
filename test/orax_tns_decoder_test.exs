defmodule OraxTnsDecoderTest do
  use ExUnit.Case, async: true

  @tti_rxh 6
  @tti_rxd 7
  @tti_rpa 8
  @tti_status 9

  # SELECT ... FOR UPDATE responses repeat the row header before every row.
  test "row headers between rows keep the rows already decoded" do
    row_format = [{:format, "ID", :in, 2, 22, -127, 0, 126}]
    # flag, num requests, iter num, num iters, buffer length, bit vector, rxhrid
    row_header = <<@tti_rxh, 0, 0, 0, 0, 0, 0, 0>>
    row = fn number -> <<@tti_rxd, 2, 193, number + 1>> end

    data = <<row_header::binary, row.(1)::binary, row_header::binary, row.(2)::binary,
             row_header::binary, row.(3)::binary, status()::binary>>

    assert {:ok, {0, ^row_format, [0], [[{1.0}], [{2.0}], [{3.0}]]}} =
             :orax_tns_decoder.decode_two_task(data, {0, row_format, []})
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
    @row_format [{:format, "ID", :in, 2, 22, -127, 0, 126}]

    defp rows_response do
      row_header = <<@tti_rxh, 0, 0, 0, 0, 0, 0, 0>>
      row = fn number -> <<@tti_rxd, 2, 193, number + 1>> end

      <<row_header::binary, row.(1)::binary, row_header::binary, row.(2)::binary,
        row_header::binary, row.(3)::binary, status()::binary>>
    end

    test "a response split at any byte decodes as a whole one" do
      data = rows_response()
      expected = :orax_tns_decoder.decode_two_task(data, {0, @row_format, []})
      assert {:ok, {0, @row_format, [0], [[{1.0}], [{2.0}], [{3.0}]]}} = expected

      for split <- 0..byte_size(data) do
        <<first::binary-size(^split), second::binary>> = data
        cont = {<<>>, {0, @row_format, []}}

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
      assert {:more, {pending, {0, @row_format, [0], [[{1.0}], [{2.0}]]}}} =
               :orax_tns_decoder.decode_response(first, {<<>>, {0, @row_format, []}}, false)

      assert pending == binary_part(data, 24, 3)
    end

    test "a response cut short is an error once it is complete" do
      data = rows_response()
      first = binary_part(data, 0, byte_size(data) - 2)

      assert {:error, {:decode_error, details}} =
               :orax_tns_decoder.decode_response(first, {<<>>, {0, @row_format, []}}, true)

      assert details[:message_type] == @tti_status
      assert details[:reason] == "incomplete_message"
    end

    test "an unknown message type is an error" do
      assert {:error, {:decode_error, details}} =
               :orax_tns_decoder.decode_response(<<0xEE, 1, 2, 3>>, {<<>>, []}, false)

      assert details[:message_type] == 0xEE
      assert details[:reason] =~ "unknown_message_type"
    end

    test "LOB data cut short is not returned as a value" do
      assert {:more, _} = :orax_tns_decoder.decode_response(<<14, 10, "abc">>, {<<>>, []}, false)
      assert {:error, {:decode_error, _}} = :orax_tns_decoder.decode_response(<<14, 10, "abc">>, {<<>>, []}, true)
      assert {:ok, {:ok, ~c"abc"}} = :orax_tns_decoder.decode_response(<<14, 3, "abc", status()::binary>>, {<<>>, []}, true)
    end
  end

  test "return parameters skip chunked keyword values" do
    data = return_parameters(<<0>>, chunked_field())
    assert_decoded(data)
  end

  test "return parameters skip chunked keywords" do
    data = return_parameters(chunked_field(), <<0>>)
    assert_decoded(data)
  end

  # end of call status, end to end sequence number
  defp status, do: <<@tti_status, 0, 0>>

  defp chunked_field do
    first_chunk = :binary.copy(<<0xAA>>, 64)
    encoded_value = <<254, 64, first_chunk::binary, 1, 0xBB, 0>>
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

  defp assert_decoded(data) do
    accumulator = {0, [], []}

    assert {:ok, ^accumulator} = :orax_tns_decoder.decode_two_task(data, accumulator)
  end

  # protocol response of Oracle AI Database 26ai Free 23.26.3 (after the message type)
  @pro_26ai Base.decode16!(
              "06007838365F36342F4C696E757820322E342E7878006903010A006603400301400366030166034803014803660301660352030152036603016603610301610366030166031F03081F0366030100640000006001240F050B0C030C0C0504050D0609070805050505050F05050505050A050505050504050607080823472347081123081141B0470083036907D003000000000000000000000000000000000000000000000000000000000000000000000000003706010101EF0F011B010101010101017FFF031003030101FF01FFFF010E0101FF01060CF6097F050FFF0D0B00FF030000000000070202040D0201000118007F010200000000"
            )

  test "the protocol response gives the server capabilities" do
    {compile_caps, runtime_caps} = :orax_tns_decoder.decode_token(:pro, @pro_26ai)
    assert byte_size(compile_caps) == 55
    assert :binary.at(compile_caps, 7) == 27
    assert runtime_caps == <<2, 1, 0, 1, 24, 0, 127, 1, 2, 0, 0, 0, 0>>
  end

  test "a protocol response cut short is incomplete" do
    short = binary_part(@pro_26ai, 0, byte_size(@pro_26ai) - 20)
    assert catch_throw(:orax_tns_decoder.decode_token(:pro, short)) == :incomplete
  end
end
