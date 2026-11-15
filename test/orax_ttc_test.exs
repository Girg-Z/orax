defmodule OraxTtcTest do
  use ExUnit.Case, async: true

  test "variable length integers" do
    assert :orax_ttc.ub4(<<0, 9>>) == {0, <<9>>}
    assert :orax_ttc.ub4(<<2, 0x03, 0xAE, 9>>) == {942, <<9>>}
    assert :orax_ttc.sb4(<<0x81, 0x7F>>) == {-127, <<>>}
    assert :orax_ttc.ub8(<<3, 1, 0, 0>>) == {65536, <<>>}
    assert :orax_ttc.skip_ub4(<<2, 1, 2, 7>>) == <<7>>
    assert :orax_ttc.skip_ub8(<<0, 7>>) == <<7>>
    assert_raise ErlangError, fn -> :orax_ttc.ub4(<<0x81, 1>>) end
    assert_raise ErlangError, fn -> :orax_ttc.ub2(<<3, 1, 2, 3>>) end
  end

  test "data ending inside a value is incomplete" do
    for fun <- [:ub1, :ub2, :ub4, :bytes, :bytes_with_length, :null_terminated],
        data <- [<<>>, <<2>>] do
      if not (fun == :ub1 and data == <<2>>) do
        assert catch_throw(apply(:orax_ttc, fun, [data])) == :incomplete
      end
    end
  end

  test "bytes: short, null and chunked" do
    assert :orax_ttc.bytes(<<3, "abc", 9>>) == {"abc", <<9>>}
    assert :orax_ttc.bytes(<<0, 9>>) == {:null, <<9>>}
    assert :orax_ttc.bytes(<<255, 9>>) == {:null, <<9>>}
    assert :orax_ttc.bytes(<<254, 1, 2, "ab", 1, 1, "c", 0, 9>>) == {"abc", <<9>>}
    assert catch_throw(:orax_ttc.bytes(<<254, 1, 2, "ab">>)) == :incomplete
    assert :orax_ttc.skip_bytes(<<254, 1, 2, "ab", 0, 9>>) == <<9>>
  end

  test "bytes with length" do
    assert :orax_ttc.bytes_with_length(<<0, 9>>) == {:null, <<9>>}
    assert :orax_ttc.str_with_length(<<1, 2, 2, "ID", 9>>) == {"ID", <<9>>}
    assert :orax_ttc.null_terminated(<<"x86", 0, 9>>) == {"x86", <<9>>}
  end
end
