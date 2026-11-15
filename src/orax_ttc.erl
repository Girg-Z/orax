%% Reading the TTC encodings of the values inside the messages, after the
%% ReadBuffer of python-oracledb thin mode (base/buffer.pyx, thin/packet.pyx).
%%
%% Every function takes the data and returns {Value, Rest}, or Rest for the
%% skip_* ones. When the data ends before the value, it throws incomplete:
%% the caller keeps the message and decodes it again with the next packet.
-module(orax_ttc).

-export([ub1/1, ub2/1, ub4/1, ub8/1, sb1/1, sb2/1, sb4/1, sb8/1]).
-export([uint16be/1, uint16le/1, uint32be/1]).
-export([raw/2, bytes/1, bytes_with_length/1, str_with_length/1, null_terminated/1]).
-export([skip/2, skip_ub1/1, skip_ub2/1, skip_ub4/1, skip_ub8/1, skip_sb4/1,
         skip_bytes/1, skip_bytes_with_length/1]).

-define(LONG_LENGTH_INDICATOR, 254).
-define(NULL_LENGTH_INDICATOR, 255).

%% Unsigned 8-bit integer, as is.
ub1(<<Value, Rest/binary>>) -> {Value, Rest};
ub1(_Data) -> throw(incomplete).

sb1(<<Value:8/signed, Rest/binary>>) -> {Value, Rest};
sb1(_Data) -> throw(incomplete).

%% Variable length integers: a length byte (the high bit marks a negative
%% value), then the value in big endian order.
ub2(Data) -> unsigned(Data, 2).
ub4(Data) -> unsigned(Data, 4).
ub8(Data) -> unsigned(Data, 8).
sb2(Data) -> signed(Data, 2).
sb4(Data) -> signed(Data, 4).
sb8(Data) -> signed(Data, 8).

unsigned(Data, Max) ->
    case integer(Data, Max) of
        {false, Value, Rest} -> {Value, Rest};
        {true, _Value, _Rest} -> error(unexpected_negative_integer)
    end.

signed(Data, Max) ->
    case integer(Data, Max) of
        {false, Value, Rest} -> {Value, Rest};
        {true, Value, Rest} -> {-Value, Rest}
    end.

integer(<<Byte, Rest/binary>>, Max) ->
    Negative = Byte band 16#80 =/= 0,
    Length = Byte band 16#7f,
    Length =< Max orelse error({integer_too_large, Length, Max}),
    case Rest of
        <<Value:Length/unit:8, Rest2/binary>> -> {Negative, Value, Rest2};
        _ -> throw(incomplete)
    end;
integer(_Data, _Max) ->
    throw(incomplete).

uint16be(<<Value:16, Rest/binary>>) -> {Value, Rest};
uint16be(_Data) -> throw(incomplete).

uint16le(<<Value:16/little, Rest/binary>>) -> {Value, Rest};
uint16le(_Data) -> throw(incomplete).

uint32be(<<Value:32, Rest/binary>>) -> {Value, Rest};
uint32be(_Data) -> throw(incomplete).

%% The given number of bytes, as is.
raw(Length, Data) ->
    case Data of
        <<Value:Length/binary, Rest/binary>> -> {Value, Rest};
        _ -> throw(incomplete)
    end.

%% Bytes after a length byte; a length of 254 is followed by chunks (ub4
%% length and bytes) up to a zero length. 0 and 255 mean no value (null).
bytes(<<0, Rest/binary>>) -> {null, Rest};
bytes(<<?NULL_LENGTH_INDICATOR, Rest/binary>>) -> {null, Rest};
bytes(<<?LONG_LENGTH_INDICATOR, Rest/binary>>) -> chunks(Rest, []);
bytes(<<Length, Rest/binary>>) -> raw(Length, Rest);
bytes(_Data) -> throw(incomplete).

chunks(Data, Acc) ->
    case ub4(Data) of
        {0, Rest} -> {iolist_to_binary(lists:reverse(Acc)), Rest};
        {Length, Rest} ->
            {Chunk, Rest2} = raw(Length, Rest),
            chunks(Rest2, [Chunk|Acc])
    end.

%% A ub4 length, then the bytes when it is not zero.
bytes_with_length(Data) ->
    case ub4(Data) of
        {0, Rest} -> {null, Rest};
        {_Length, Rest} -> bytes(Rest)
    end.

str_with_length(Data) -> bytes_with_length(Data).

%% Bytes up to a zero byte, which is skipped.
null_terminated(Data) ->
    case binary:match(Data, <<0>>) of
        {Pos, 1} ->
            <<Value:Pos/binary, 0, Rest/binary>> = Data,
            {Value, Rest};
        nomatch -> throw(incomplete)
    end.

skip(Length, Data) -> element(2, raw(Length, Data)).
skip_ub1(Data) -> element(2, ub1(Data)).
skip_ub2(Data) -> element(3, integer(Data, 2)).
skip_ub4(Data) -> element(3, integer(Data, 4)).
skip_ub8(Data) -> element(3, integer(Data, 8)).
skip_sb4(Data) -> element(3, integer(Data, 4)).
skip_bytes(Data) -> element(2, bytes(Data)).
skip_bytes_with_length(Data) -> element(2, bytes_with_length(Data)).
