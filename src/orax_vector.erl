%% The image of the VECTOR type, after base/vector.pyx of python-oracledb
%% (VectorDecoder and VectorEncoder).
%%
%% Image: magic byte 0xDB, version (1 byte), flags (2 bytes), storage format
%% (1 byte), number of dimensions (4 bytes), then 8 bytes of norm when the
%% flags say NORM or NORM_RESERVED (decoding skips them, encoding leaves
%% them zero, as python only reserves the space). A dense vector goes on with
%% the values. A sparse vector (flag SPARSE) goes on with the number of
%% non-zero elements (2 bytes), their indices (4 bytes each) and their
%% values. FLOAT32/FLOAT64 are Oracle BINARY_FLOAT/DOUBLE, INT8 is one signed
%% byte, BINARY is dims/8 bytes. All integers are big endian.
%%
%% Representation:
%%   {float32, [float()]}, {float64, [float()]}, {int8, [integer()]},
%%   {binary, Bytes}, and
%%   {sparse, float32 | float64 | int8, NumDimensions, Indices, Values}.
%% Floats that Erlang cannot hold are the atoms nan, infinity, '-infinity'.
%% Python has no sparse BINARY vectors, so neither does this module.
-module(orax_vector).

-export([decode/1, encode/1]).

-define(TNS_VECTOR_MAGIC_BYTE, 16#DB).
-define(TNS_VECTOR_VERSION_BASE, 0).
-define(TNS_VECTOR_VERSION_WITH_BINARY, 1).
-define(TNS_VECTOR_VERSION_WITH_SPARSE, 2).
-define(TNS_VECTOR_FLAG_NORM, 16#0002).
-define(TNS_VECTOR_FLAG_NORM_RESERVED, 16#0010).
-define(TNS_VECTOR_FLAG_SPARSE, 16#0020).
-define(VECTOR_FORMAT_FLOAT32, 2).
-define(VECTOR_FORMAT_FLOAT64, 3).
-define(VECTOR_FORMAT_INT8, 4).
-define(VECTOR_FORMAT_BINARY, 5).

decode(<<?TNS_VECTOR_MAGIC_BYTE, Version, Flags:16, Format, NumElements:32,
         Rest/binary>>) ->
    Version =< ?TNS_VECTOR_VERSION_WITH_SPARSE
        orelse error({vector, {version_not_supported, Version}}),
    Rest1 = case Flags band (?TNS_VECTOR_FLAG_NORM_RESERVED bor
                             ?TNS_VECTOR_FLAG_NORM) of
                0 -> Rest;
                _ -> <<_Norm:8/binary, R/binary>> = Rest, R
            end,
    case Flags band ?TNS_VECTOR_FLAG_SPARSE of
        0 ->
            decode_values(Rest1, NumElements, Format);
        _ ->
            <<NumSparse:16, Rest2/binary>> = Rest1,
            IndicesSize = NumSparse * 4,
            <<IndicesBin:IndicesSize/binary, Rest3/binary>> = Rest2,
            Indices = [I || <<I:32>> <= IndicesBin],
            sparse_format(Format),
            {Fmt, Values} = decode_values(Rest3, NumSparse, Format),
            {sparse, Fmt, NumElements, Indices, Values}
    end;
decode(<<Magic, _/binary>>) when Magic =/= ?TNS_VECTOR_MAGIC_BYTE ->
    error({vector, {unexpected_data, Magic}});
decode(_) ->
    error({vector, truncated}).

decode_values(Bin, N, ?VECTOR_FORMAT_FLOAT32) ->
    Size = N * 4,
    <<B:Size/binary, _/binary>> = Bin,
    {float32, [orax_values:binary_float(X) || <<X:4/binary>> <= B]};
decode_values(Bin, N, ?VECTOR_FORMAT_FLOAT64) ->
    Size = N * 8,
    <<B:Size/binary, _/binary>> = Bin,
    {float64, [orax_values:binary_float(X) || <<X:8/binary>> <= B]};
decode_values(Bin, N, ?VECTOR_FORMAT_INT8) ->
    <<B:N/binary, _/binary>> = Bin,
    {int8, [X || <<X:8/signed>> <= B]};
decode_values(Bin, N, ?VECTOR_FORMAT_BINARY) ->
    Size = N div 8,
    <<B:Size/binary, _/binary>> = Bin,
    {binary, B};
decode_values(_, _, Format) ->
    error({vector, {format_not_supported, Format}}).

sparse_format(?VECTOR_FORMAT_BINARY) ->
    error({vector, {format_not_supported, ?VECTOR_FORMAT_BINARY}});
sparse_format(_) ->
    ok.

encode({sparse, Format, NumDimensions, Indices, Values}) ->
    Fmt = format_code(Format),
    Fmt =/= ?VECTOR_FORMAT_BINARY
        orelse error({vector, {format_not_supported, Format}}),
    NumSparse = length(Indices),
    NumSparse =:= length(Values)
        orelse error({vector, indices_values_mismatch}),
    Flags = ?TNS_VECTOR_FLAG_NORM_RESERVED bor ?TNS_VECTOR_FLAG_SPARSE bor
            ?TNS_VECTOR_FLAG_NORM,
    Header = header(?TNS_VECTOR_VERSION_WITH_SPARSE, Flags, Fmt,
                    NumDimensions),
    iolist_to_binary([Header, <<NumSparse:16>>, [<<I:32>> || I <- Indices],
                      encode_values(Format, Values)]);
encode({binary, Bin}) when is_binary(Bin) ->
    Flags = ?TNS_VECTOR_FLAG_NORM_RESERVED,
    iolist_to_binary([header(?TNS_VECTOR_VERSION_WITH_BINARY, Flags,
                             ?VECTOR_FORMAT_BINARY, byte_size(Bin) * 8), Bin]);
encode({Format, Values}) when is_list(Values) ->
    Fmt = format_code(Format),
    Flags = ?TNS_VECTOR_FLAG_NORM_RESERVED bor ?TNS_VECTOR_FLAG_NORM,
    iolist_to_binary([header(?TNS_VECTOR_VERSION_BASE, Flags, Fmt,
                             length(Values)),
                      encode_values(Format, Values)]);
encode(Other) ->
    error({vector, {bad_value, Other}}).

%% The header, followed by the 8 reserved bytes of the norm.
header(Version, Flags, Format, NumElements) ->
    <<?TNS_VECTOR_MAGIC_BYTE, Version, Flags:16, Format, NumElements:32,
      0:64>>.

format_code(float32) -> ?VECTOR_FORMAT_FLOAT32;
format_code(float64) -> ?VECTOR_FORMAT_FLOAT64;
format_code(int8) -> ?VECTOR_FORMAT_INT8;
format_code(binary) -> ?VECTOR_FORMAT_BINARY;
format_code(Other) -> error({vector, {format_not_supported, Other}}).

encode_values(float32, Values) ->
    [oracle_float(<<(float_bits(32, V))/binary>>) || V <- Values];
encode_values(float64, Values) ->
    [oracle_float(<<(float_bits(64, V))/binary>>) || V <- Values];
encode_values(int8, Values) ->
    [<<V:8/signed>> || V <- Values].

float_bits(32, nan) -> <<16#7FC00000:32>>;
float_bits(32, infinity) -> <<16#7F800000:32>>;
float_bits(32, '-infinity') -> <<16#FF800000:32>>;
float_bits(32, V) -> <<V:32/float>>;
float_bits(64, nan) -> <<16#7FF8000000000000:64>>;
float_bits(64, infinity) -> <<16#7FF0000000000000:64>>;
float_bits(64, '-infinity') -> <<16#FFF0000000000000:64>>;
float_bits(64, V) -> <<V:64/float>>.

oracle_float(<<0:1, Rest/bitstring>>) -> <<1:1, Rest/bitstring>>;
oracle_float(Bin) ->
    Size = bit_size(Bin),
    <<X:Size>> = Bin,
    <<(bnot X):Size>>.
