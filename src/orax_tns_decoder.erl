%% Decoding the TNS packets and the TTC messages of the responses, after the
%% Message classes of python-oracledb thin mode (thin/messages/base.pyx and
%% the messages of each request): one function per message type, each one
%% updating a #resp{} with what it carries. Which fields a message has depends
%% on the negotiated capabilities (#caps{}, the field version above all).
-module(orax_tns_decoder).

%% API
-export([decode_packet/2]).
-export([decode_response/3]).
-export([decode_token/2]).

-include("orax.hrl").

-import(orax_ttc, [ub1/1, ub2/1, ub4/1, ub8/1, sb1/1, sb4/1, raw/2, bytes/1,
                   bytes_with_length/1, null_terminated/1, uint16be/1, uint16le/1,
                   skip/2, skip_ub1/1, skip_ub2/1, skip_ub4/1, skip_ub8/1, skip_sb4/1,
                   skip_bytes/1, skip_bytes_with_length/1]).

%% API

%% Splits the first TNS packet off the bytes received so far. Packet lengths
%% take 32 bits once TNS version 315 or later is negotiated (large SDU), and
%% 16 bits before that (connect phase and older servers).
decode_packet(<<Size:32, Type, Flags, _Checksum:16, _/bits>> = Data, Version) when Version >= 315 ->
    split_packet(Data, Size, Type, Flags);
decode_packet(<<Size:16, _Checksum:16, Type, Flags, _HeaderChecksum:16, _/bits>> = Data, Version) when Version < 315 ->
    split_packet(Data, Size, Type, Flags);
decode_packet(_Data, _Version) ->
    more.

split_packet(_Data, Size, _Type, _Flags) when Size < 8 ->
    {error, {packet_length, Size}};
split_packet(Data, Size, Type, Flags) ->
    case Data of
        <<_Header:8/binary, Payload:(Size-8)/binary, Rest/bits>> ->
            {ok, Type, Flags, Payload, Rest};
        _ ->
            more
    end.

%% Decodes a TTC response message by message, as its packets arrive. Cont is
%% {Pending, Resp}: the start of a message that is not complete yet and the
%% #resp{} decoded so far. When a message runs past the data received,
%% decoding stops before it and returns {more, Cont}; the next packet resumes
%% it. Final means the response is complete (end of response seen), so a
%% message cut short is an error.
decode_response(Data, {Pending, Resp}, Final) ->
    decode_messages(<<Pending/binary, Data/binary>>, Resp, Final).

decode_messages(_Data, #resp{end_of_response=true} = Resp, _Final) ->
    {ok, Resp};
decode_messages(<<>>, #resp{call_ended=true} = Resp, true) ->
    {ok, Resp};
decode_messages(<<>>, _Resp, true) ->
    {error, {decode_error, [{reason, incomplete_response}]}};
decode_messages(<<>>, Resp, false) ->
    {more, {<<>>, Resp}};
decode_messages(<<Type, Body/binary>> = Data, Resp, Final) ->
    case try_message(Type, Body, Resp) of
        {ok, Rest, Resp2} -> decode_messages(Rest, Resp2, Final);
        incomplete when Final -> {error, decode_error(Type, incomplete_message, [])};
        incomplete -> {more, {Data, Resp}};
        {failed, Reason, Stack} -> {error, decode_error(Type, Reason, Stack)}
    end.

try_message(Type, Body, Resp) ->
    try message(Type, Body, Resp) of
        {Rest, Resp2} -> {ok, Rest, Resp2}
    catch
        throw:incomplete -> incomplete;
        Class:Reason:Stack -> {failed, {Class, Reason}, Stack}
    end.

decode_error(Type, Reason, Stack) ->
    {decode_error, [
        {message_type, Type},
        {reason, iolist_to_binary(io_lib:format("~0P", [Reason, 12]))},
        {stacktrace, [{M, F, A, proplists:get_value(line, Loc)} || {M, F, A, Loc} <- lists:sublist(Stack, 3)]}
    ]}.

%% The redirect data: the address to connect to instead.
decode_token(net, {Data, EnvOpts}) ->
    Values = lists:map(fun(L) -> list_to_tuple(string:tokens(L, "=")) end,
             string:tokens(binary_to_list(hd(binary:split(Data, <<0>>))), "()")),
    Host = proplists:get_value("HOST", Values),
    Port = proplists:get_value("PORT", Values),
    {ok, [{host, Host}, {port, list_to_integer(Port)}]++EnvOpts}.

%% Messages

%% The messages of the protocol, data types and authentication requests.
message(?TTI_PRO, Data, #resp{msg=protocol} = Resp) ->
    protocol_info(Data, Resp);
message(?TTI_DTY, Data, #resp{msg=data_types} = Resp) ->
    data_types(Data, Resp);
message(?TTI_RPA, Data, #resp{msg=auth} = Resp) ->
    auth_parameters(Data, Resp);
%% The messages of an execute or a fetch (MessageWithData).
message(?TTI_RXH, Data, #resp{msg=execute} = Resp) ->
    row_header(Data, Resp);
message(?TTI_RXD, Data, #resp{msg=execute} = Resp) ->
    row_data(Data, Resp);
message(?TTI_FOB, Data, #resp{msg=execute} = Resp) ->
    {Data, Resp#resp{flush_out_binds=true, end_of_response=true}};
message(?TTI_DCB, Data, #resp{msg=execute} = Resp) ->
    {Columns, Rest} = describe_info(skip_bytes(Data), Resp),
    {Rest, Resp#resp{columns=Columns, out=Columns}};
message(?TTI_BVC, Data, #resp{msg=execute} = Resp) ->
    bit_vector(Data, Resp);
message(?TTI_IOV, Data, #resp{msg=execute} = Resp) ->
    io_vector(Data, Resp);
message(?TTI_IMPLICIT, Data, #resp{msg=execute} = Resp) ->
    implicit_result(Data, Resp);
message(?TTI_RPA, Data, #resp{msg=execute} = Resp) ->
    return_parameters(Data, Resp);
%% The messages of every response (Message).
message(?TTI_OER, Data, Resp) ->
    error_info(Data, Resp);
message(?TTI_WRN, Data, Resp) ->
    warning_info(Data, Resp);
message(?TTI_TOKEN, Data, Resp) ->
    {skip_ub8(Data), Resp};                 %token number
message(?TTI_STA, Data, #resp{caps=Caps} = Resp) ->
    {Status, A} = ub4(Data),                %call status
    B = skip_ub2(A),                        %end to end sequence number
    {B, Resp#resp{call_status=Status, call_ended=true,
                  end_of_response=not Caps#caps.end_of_response}};
message(?TTI_SSPB, Data, Resp) ->
    server_side_piggyback(Data, Resp);
message(?TTI_EOR, Data, Resp) ->
    {Data, Resp#resp{end_of_response=true}};
message(Type, _Data, _Resp) ->
    error({unknown_message_type, Type}).

%% The protocol response: server version, banner, character sets, then the
%% server compile time and runtime capabilities (protocol.pyx).
protocol_info(Data, Resp) ->
    A = skip_ub1(Data),                     %server version
    B = skip_ub1(A),                        %zero byte
    {_Banner, C} = null_terminated(B),
    {_Charset, D} = uint16le(C),
    E = skip_ub1(D),                        %server flags
    {NumElem, F} = uint16le(E),
    G = skip(NumElem * 5, F),
    {FdoLength, H} = uint16be(G),
    I = skip(FdoLength, H),
    {CompileCaps, J} = bytes(I),
    {RuntimeCaps, K} = bytes(J),
    {K, Resp#resp{server_caps={nullable(CompileCaps), nullable(RuntimeCaps)},
                  end_of_response=true}}.

%% The data types the server accepts, up to a zero type (data_types.pyx).
data_types(Data, Resp) ->
    case uint16be(Data) of
        {0, Rest} ->
            {Rest, Resp#resp{end_of_response=true}};
        {_DataType, A} ->
            case uint16be(A) of
                {0, B} -> data_types(B, Resp);
                {_ConvDataType, B} -> data_types(skip(4, B), Resp)
            end
    end.

%% The key/value pairs of the authentication (auth.pyx).
auth_parameters(Data, Resp) ->
    {Num, A} = ub2(Data),
    {Values, B} = auth_values(A, Num, []),
    {B, Resp#resp{session_data=Values}}.

auth_values(Data, 0, Acc) ->
    {lists:reverse(Acc), Data};
auth_values(Data, Num, Acc) ->
    {Key, A} = bytes_with_length(Data),
    {Value, B} = bytes_with_length(A),
    {Flags, C} = ub4(B),                    %flags (verifier type for AUTH_VFR_DATA)
    auth_values(C, Num - 1, [{to_list(Key), to_list(Value), Flags}|Acc]).

%% The end of a call, with an error or not (Message._process_error_info).
%% Without the end of response marker, it also ends the response.
error_info(Data, #resp{caps=Caps} = Resp) ->
    {CallStatus, A} = ub4(Data),            %end of call status
    B = skip_ub2(A),                        %end to end seq#
    C = skip_ub4(B),                        %current row number
    D = skip_ub2(C),                        %error number
    E = skip_ub2(skip_ub2(D)),              %array elem error
    {CursorId, F} = ub2(E),                 %cursor id
    {ErrorPos, G} = orax_ttc:sb2(F),        %error position
    H = skip(5, G),                         %sql type, fatal, flags, user cursor options, UPI parameter
    I = skip_ub1(H),                        %warning flags
    J = skip_rowid(I),                      %rowid
    K = skip_ub4(J),                        %OS error
    L = skip(2, K),                         %statement number, call number
    M = skip_ub2(L),                        %padding
    N = skip_ub4(M),                        %success iters
    O = skip_bytes_with_length(N),          %oerrdd (logical rowid)
    P = batch_errors(O),
    {ErrorNum, Q} = ub4(P),                 %error number (extended)
    {RowCount, R} = ub8(Q),                 %row number (extended)
    %% python-oracledb reads these with the negotiated field version, but a
    %% 26ai server sends them even when the client asks for 19c's (12): they
    %% follow the version the server declares.
    S =
    case Caps#caps.server_field_version >= ?TNS_CCAP_FIELD_VERSION_20_1 of
        true -> skip_ub4(skip_ub4(R));      %sql type, server checksum
        false -> R
    end,
    {Message, T} =
    case ErrorNum of
        0 -> {[], S};
        _ -> {Bin, Rest} = bytes(S), {to_list(Bin), Rest}
    end,
    CursorId2 = if CursorId =/= 0 -> CursorId; true -> Resp#resp.cursor_id end,
    {T, Resp#resp{call_status=CallStatus, cursor_id=CursorId2, error_num=ErrorNum,
                  error_pos=ErrorPos, error_message=Message, rowcount=RowCount,
                  call_ended=true, end_of_response=not Caps#caps.end_of_response}}.

%% The codes, row offsets and messages of the errors of an array DML with
%% batch errors.
batch_errors(Data) ->
    {NumErrors, A} = ub2(Data),             %batch error codes array
    B = array_of(NumErrors, fun orax_ttc:skip_ub2/1, A),
    {NumOffsets, C} = ub4(B),               %batch error row offset array
    D = array_of(NumOffsets, fun orax_ttc:skip_ub4/1, C),
    {NumMessages, E} = ub2(D),              %batch error messages array
    case NumMessages of
        0 -> E;
        _ ->
            F = skip(1, E),                 %packed size
            repeat(NumMessages, fun(X) -> skip(2, skip_bytes(skip_ub2(X))) end, F)
    end.

array_of(0, _Skip, Data) ->
    Data;
array_of(Num, Skip, Data) ->
    {FirstByte, A} = ub1(Data),
    Long = FirstByte =:= ?TNS_LONG_LENGTH_INDICATOR,
    B = repeat(Num, fun(X) -> Skip(if Long -> skip_ub4(X); true -> X end) end,
               if Long -> A; true -> Data end),
    if Long -> skip(1, B); true -> B end.

%% The packed rowid of the error info (rowid of the last row changed).
skip_rowid(Data) ->
    skip_ub2(skip_ub4(skip_ub1(skip_ub2(skip_ub4(Data))))).

warning_info(Data, Resp) ->
    {ErrorNum, A} = ub2(Data),              %error number
    {Length, B} = ub2(A),                   %length of error message
    C = skip_ub2(B),                        %flags
    D = case ErrorNum =/= 0 andalso Length > 0 of
        true -> skip_bytes(C);
        false -> C
    end,
    {D, Resp}.

server_side_piggyback(Data, Resp) ->
    {Opcode, A} = ub1(Data),
    {piggyback(Opcode, A), Resp}.

piggyback(?TNS_SERVER_PIGGYBACK_LTXID, Data) ->
    skip_bytes_with_length(Data);
piggyback(Opcode, Data) when Opcode =:= ?TNS_SERVER_PIGGYBACK_QUERY_CACHE_INVALIDATION;
                                         Opcode =:= ?TNS_SERVER_PIGGYBACK_TRACE_EVENT ->
    Data;
piggyback(?TNS_SERVER_PIGGYBACK_OS_PID_MTS, Data) ->
    skip_bytes(skip_ub2(Data));
piggyback(?TNS_SERVER_PIGGYBACK_SYNC, Data) ->
    A = skip_ub1(skip_ub2(Data)),           %number and length of DTYs
    {Num, B} = ub2(A),
    C = skip_ub1(B),
    skip_ub4(keyword_value_pairs(C, Num)); %overall flags
piggyback(?TNS_SERVER_PIGGYBACK_EXT_SYNC, Data) ->
    skip_ub1(skip_ub2(Data));
piggyback(?TNS_SERVER_PIGGYBACK_AC_REPLAY_CONTEXT, Data) ->
    A = skip_ub1(skip_ub2(Data)),           %number and length of DTYs
    B = skip_ub1(skip_ub4(skip_ub4(A))),    %flags, error code, queue
    skip_bytes_with_length(B);              %replay context
piggyback(?TNS_SERVER_PIGGYBACK_SESS_RET, Data) ->
    A = skip_ub1(skip_ub2(Data)),
    {Num, B} = ub2(A),
    C = case Num of
        0 -> B;
        _ ->
            repeat(Num, fun(X) ->
                X2 = skip_if_length(X),     %key
                skip_ub2(skip_if_length(X2))  %value, flags
            end, skip_ub1(B))
    end,
    skip_ub2(skip_ub4(skip_ub4(C)));        %session flags, session id, serial number
piggyback(?TNS_SERVER_PIGGYBACK_SESS_SIGNATURE, Data) ->
    A = skip_ub1(skip_ub2(Data)),           %number and length of DTYs
    skip_ub8(skip_ub8(skip_ub8(A)));        %signature flags, client and server signatures
piggyback(Opcode, _Data) ->
    error({unknown_server_piggyback, Opcode}).

skip_if_length(Data) ->
    case ub2(Data) of
        {0, A} -> A;
        {_, A} -> skip_bytes(A)
    end.

keyword_value_pairs(Data, Num) ->
    repeat(Num, fun(X) ->
        A = skip_if_length(X),              %text value
        B = skip_if_length(A),              %binary value
        skip_ub2(B)                         %keyword number
    end, Data).

%% The return parameters of an execute (MessageWithData).
return_parameters(Data, Resp) ->
    {NumParams, A} = ub2(Data),             %al8o4l
    B = repeat(NumParams, fun orax_ttc:skip_ub4/1, A),
    {NumBytes, C} = ub2(B),                 %al8txl
    D = skip(NumBytes, C),
    {NumPairs, E} = ub2(D),                 %key/value pairs
    F = keyword_value_pairs(E, NumPairs),
    {RegLength, G} = ub2(F),                %registration info
    {skip(RegLength, G), Resp}.

%% Execute and fetch

%% The columns of a query (_process_describe_info).
describe_info(Data, Resp) ->
    A = skip_ub4(Data),                     %max row size
    {NumColumns, B} = ub4(A),
    C = if NumColumns > 0 -> skip_ub1(B); true -> B end,
    {Columns, D} = repeat_acc(NumColumns, fun(X) -> metadata(X, Resp) end, C),
    E = skip_bytes_with_length(D),          %current date
    F = skip_ub4(skip_ub4(skip_ub4(skip_ub4(E)))),  %dcbflag, dcbmdbz, dcbmnpr, dcbmxpr
    {Columns, skip_bytes_with_length(F)}.   %dcbqcky

%% The metadata of a column (_process_metadata).
metadata(Data, #resp{caps=#caps{field_version=Version}}) ->
    {DataType, A} = ub1(Data),
    B = skip_ub1(A),                        %flags
    {Precision, C} = sb1(B),
    {Scale, D} = sb1(C),
    {BufferSize, E} = ub4(D),
    F = skip_ub8(skip_ub4(E)),              %max number of array elements, cont flags
    G = skip_bytes_with_length(F),          %OID
    H = skip_ub2(skip_ub2(G)),              %version, character set id
    {Csfrm, I} = ub1(H),                    %character set form
    {MaxSize, J} = ub4(I),
    K = if Version >= ?TNS_CCAP_FIELD_VERSION_12_2 -> skip_ub4(J); true -> J end,  %oaccolid
    L = skip_ub1(skip_ub1(K)),              %nulls allowed, v7 length of name
    {Name, M} = bytes_with_length(L),
    N = skip_bytes_with_length(skip_bytes_with_length(M)),  %schema, type name
    O = skip_ub2(N),                        %column position
    {UdsFlags, P} = ub4(O),
    Q = if Version >= ?TNS_CCAP_FIELD_VERSION_23_1 ->
            skip_bytes_with_length(skip_bytes_with_length(P));  %domain schema and name
        true -> P
    end,
    R = if Version >= ?TNS_CCAP_FIELD_VERSION_23_1_EXT_3 -> annotations(Q); true -> Q end,
    {{Dimensions, VectorFormat, VectorFlags}, S} =
    case Version >= ?TNS_CCAP_FIELD_VERSION_23_4 of
        true ->
            {Dim, S1} = ub4(R),
            {Fmt, S2} = ub1(S1),
            {Flg, S3} = ub1(S2),
            {{Dim, Fmt, Flg}, S3};
        false -> {{0, 0, 0}, R}
    end,
    MaxSize2 = if DataType =:= ?TNS_TYPE_RAW -> BufferSize; true -> MaxSize end,
    {#format{column_name=nullable(Name), data_type=DataType, data_length=BufferSize,
             data_scale=Scale, data_precision=Precision, csfrm=Csfrm, max_size=MaxSize2,
             is_json=UdsFlags band ?TNS_UDS_FLAGS_IS_JSON =/= 0,
             is_oson=UdsFlags band ?TNS_UDS_FLAGS_IS_OSON =/= 0,
             vector_dimensions=Dimensions, vector_format=VectorFormat,
             vector_flags=VectorFlags}, S}.

annotations(Data) ->
    case ub4(Data) of
        {0, A} -> A;
        {_, A} ->
            {Num, B} = ub4(skip_ub1(A)),
            C = repeat(Num, fun(X) ->
                skip_ub4(skip_bytes_with_length(skip_bytes_with_length(X)))  %key, value, flags
            end, skip_ub1(B)),
            skip_ub4(C)                     %flags
    end.

row_header(Data, Resp) ->
    A = skip_ub2(skip_ub1(Data)),           %flags, num requests
    B = skip_ub2(skip_ub4(skip_ub4(A))),    %iteration number, num iters, buffer length
    {NumBytes, C} = ub4(B),
    {BitVector, D} =
    case NumBytes of
        0 -> {Resp#resp.bit_vector, C};
        _ -> raw(NumBytes, skip_ub1(C))     %repeated length, bit vector
    end,
    {skip_bytes_with_length(D), Resp#resp{bit_vector=BitVector}}.  %rxhrid

bit_vector(Data, #resp{columns=Columns} = Resp) ->
    A = skip_ub2(Data),                     %number of columns sent
    NumBytes = (length(Columns) + 7) div 8,
    {BitVector, B} = raw(NumBytes, A),
    {B, Resp#resp{bit_vector=BitVector}}.

%% The directions of the binds of a PL/SQL block: the row data that follows
%% has the values of the binds that are not input only.
io_vector(Data, #resp{binds=Binds} = Resp) ->
    A = skip_ub1(Data),                     %flag
    {NumRequests, B} = ub2(A),
    {NumIters, C} = ub4(B),
    NumBinds = NumIters * 256 + NumRequests,
    D = skip_ub2(skip_ub4(C)),              %num iters this time, uac buffer length
    E = skip_if_length_raw(D),              %bit vector for fast fetch
    F = skip_if_length_raw(E),              %rowid
    {Directions, G} = raw(NumBinds, F),
    Out = [Bind#format{param=out} || {Dir, Bind} <- lists:zip(binary_to_list(Directions),
                                                             lists:sublist(Binds, NumBinds)),
                                     Dir =/= ?TNS_BIND_DIR_INPUT],
    {G, Resp#resp{out=Out}}.

skip_if_length_raw(Data) ->
    {Length, A} = ub2(Data),
    skip(Length, A).

%% Result sets returned with DBMS_SQL.RETURN_RESULT: read and dropped.
implicit_result(Data, Resp) ->
    {Num, A} = ub4(Data),
    {repeat(Num, fun(X) ->
        {Length, X2} = ub1(X),
        {_Columns, X3} = describe_info(skip(Length, X2), Resp),
        skip_ub2(X3)                        %cursor id
    end, A), Resp}.

%% A row of a query, the values of the return binds of a DML or the values
%% of the out binds of a PL/SQL block (_process_row_data).
row_data(Data, #resp{returning=true, out=Out, rows=Rows} = Resp) ->
    {Values, Rest} = repeat_acc(length(Out), Out, fun(X, Format) ->
        {Num, X2} = ub4(X),
        repeat_acc(Num, fun(X3) -> column_data(X3, Format, Resp) end, X2)
    end, Data),
    {Rest, Resp#resp{rows=[Values|Rows]}};
row_data(Data, #resp{in_fetch=true, out=Out, bit_vector=BitVector, last_row=LastRow, rows=Rows} = Resp) ->
    {Row, Rest} = fetch_row(Data, Out, 0, BitVector, LastRow, Resp, []),
    {Rest, Resp#resp{rows=[Row|Rows], last_row=Row, bit_vector=undefined}};
row_data(Data, #resp{out=Out, rows=Rows} = Resp) ->
    {Values, Rest} = repeat_acc(length(Out), Out,
                                fun(X, Format) -> column_data(X, Format, Resp) end, Data),
    {Rest, Resp#resp{rows=[Values|Rows]}}.

fetch_row(Data, [], _I, _BitVector, _LastRow, _Resp, Acc) ->
    {lists:reverse(Acc), Data};
fetch_row(Data, [Format|Formats], I, BitVector, LastRow, Resp, Acc) ->
    {Value, Rest} =
    case duplicate(BitVector, I) of
        true -> {lists:nth(I + 1, LastRow), Data};
        false -> column_data(Data, Format, Resp)
    end,
    fetch_row(Rest, Formats, I + 1, BitVector, LastRow, Resp, [Value|Acc]).

%% A column whose bit is clear in the bit vector is not sent: it has the
%% value of the previous row.
duplicate(undefined, _I) ->
    false;
duplicate(BitVector, I) ->
    binary:at(BitVector, I div 8) band (1 bsl (I rem 8)) =:= 0.

%% Values

%% A value of a column or bind (_process_column_data). Out binds end with the
%% actual length; LONG columns with an indicator and a return code.
column_data(Data, #format{data_type=DataType, data_length=0}, #resp{in_fetch=true})
  when DataType =/= ?TNS_TYPE_LONG, DataType =/= ?TNS_TYPE_LONGRAW, DataType =/= ?TNS_TYPE_UROWID ->
    {null, Data};                           %column is null by describe
column_data(Data, #format{data_type=DataType} = Format, #resp{in_fetch=InFetch} = Resp) ->
    {Value, Rest} = value(Data, Format, Resp),
    case InFetch of
        false ->
            {ActualLength, Rest2} = sb4(Rest),
            case DataType of
                ?TNS_TYPE_BOOLEAN when ActualLength < 0 -> {null, Rest2};
                _ -> {Value, Rest2}
            end;
        true when ?IS_LONG_TYPE(DataType) ->
            {Value, skip_ub4(skip_sb4(Rest))};  %null indicator, return code
        true ->
            {Value, Rest}
    end.

value(Data, #format{data_type=DataType}, #resp{in_fetch=InFetch}) when ?IS_ROWID_TYPE(DataType) ->
    case InFetch of
        false -> text(Data, ?CS_FORM_IMPLICIT);
        true ->
            case ub1(Data) of
                {Length, Rest} when Length =:= 0; Length =:= ?TNS_NULL_LENGTH_INDICATOR -> {null, Rest};
                {_Length, Rest} -> rowid(Rest)
            end
    end;
value(Data, #format{data_type=?TNS_TYPE_UROWID}, #resp{in_fetch=false}) ->
    text(Data, ?CS_FORM_IMPLICIT);
value(Data, #format{data_type=?TNS_TYPE_UROWID}, _Resp) ->
    urowid(Data);
value(Data, #format{data_type=?TNS_TYPE_REFCURSOR}, Resp) ->
    {Columns, A} = describe_info(skip_ub1(Data), Resp),  %length (fixed value)
    {CursorId, B} = ub2(A),
    {{cursor, CursorId, Columns}, B};
value(Data, #format{data_type=DataType}, _Resp) when ?IS_LOB_TYPE(DataType); DataType =:= ?TNS_TYPE_BFILE ->
    lob(Data, DataType);
value(Data, #format{data_type=?TNS_TYPE_JSON}, _Resp) ->
    prefetched_lob(Data, fun orax_oson:decode/1);
value(Data, #format{data_type=?TNS_TYPE_VECTOR}, _Resp) ->
    prefetched_lob(Data, fun orax_vector:decode/1);
value(Data, #format{data_type=?TNS_TYPE_ADT}, _Resp) ->
    dbobject(Data);
value(Data, Format, _Resp) ->
    case bytes(Data) of
        {null, Rest} -> {null, Rest};
        {Bin, Rest} -> {oracle_data(Bin, Format), Rest}
    end.

%% The values sent as bytes (read_oracle_data).
oracle_data(Bin, #format{data_type=DataType}) when ?IS_BINARY_TYPE(DataType) ->
    {orax_values:binary_float(Bin)};
oracle_data(<<Byte, _/binary>>, #format{data_type=?TNS_TYPE_BOOLEAN}) ->
    Byte =:= 1;
oracle_data(Bin, #format{data_type=DataType, csfrm=Csfrm})
  when ?IS_CHAR_TYPE(DataType); ?IS_RAW_TYPE(DataType); ?IS_LONG_TYPE(DataType) ->
    to_list(charset(Bin, Csfrm));
oracle_data(Bin, #format{data_type=DataType}) when ?IS_DATE_TYPE(DataType) ->
    orax_values:date(Bin);
oracle_data(Bin, #format{data_type=DataType}) when ?IS_INTERVAL_TYPE(DataType) ->
    orax_values:interval(Bin);
oracle_data(Bin, #format{data_type=DataType, data_scale=Scale, data_precision=Precision})
  when ?IS_NUMBER_TYPE(DataType); DataType =:= ?TNS_TYPE_BINARY_INTEGER ->
    {orax_values:number(Bin, Scale, Precision)};
oracle_data(_Bin, #format{data_type=DataType}) ->
    error({data_type_not_supported, DataType}).

%% National character set values come in UTF-16, the others in the client
%% character set.
charset(Bin, ?CS_FORM_NCHAR) -> unicode:characters_to_binary(Bin, utf16);
charset(Bin, _Csfrm) -> Bin.

text(Data, Csfrm) ->
    case bytes(Data) of
        {null, Rest} -> {null, Rest};
        {Bin, Rest} -> {to_list(charset(Bin, Csfrm)), Rest}
    end.

%% A physical rowid: object, file, block and row in base 64.
rowid(Data) ->
    {Rba, A} = ub4(Data),
    {PartitionId, B} = ub2(A),
    {BlockNum, C} = ub4(skip_ub1(B)),
    {SlotNum, D} = ub2(C),
    {encode_rowid(Rba, PartitionId, BlockNum, SlotNum), D}.

%% A universal rowid: a physical rowid, or the bytes of a logical one (index
%% organized tables) in base 64 after a "*" (read_urowid).
urowid(Data) ->
    case bytes(Data) of                     %the length, ignored
        {null, Rest} -> {null, Rest};
        {_Length, Rest} ->
            case bytes(Rest) of
                {<<1, Rba:32, PartitionId:16, BlockNum:32, SlotNum:16, _/binary>>, Rest2} ->
                    {encode_rowid(Rba, PartitionId, BlockNum, SlotNum), Rest2};
                {<<_, Logical/binary>> = Bin, Rest2} when byte_size(Bin) >= 13 ->
                    {[$*|binary_to_list(base64:encode(Logical, #{padding => false}))], Rest2}
            end
    end.

encode_rowid(Rba, PartitionId, BlockNum, SlotNum) ->
    base64_digits(Rba, 6) ++ base64_digits(PartitionId, 3) ++
        base64_digits(BlockNum, 6) ++ base64_digits(SlotNum, 3).

base64_digits(N, Count) ->
    [lists:nth(((N bsr (6 * I)) band 63) + 1,
               "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
     || I <- lists:seq(Count - 1, 0, -1)].

%% A LOB locator, with size and chunk size (read_lob_with_length). orax
%% defines LOB columns as LONG, so locators only come for LOB out binds.
lob(Data, DataType) ->
    case ub4(Data) of
        {0, Rest} -> {null, Rest};
        {_Length, A} ->
            {Size, B} =
            case DataType of
                ?TNS_TYPE_BFILE -> {0, A};
                _ -> {S, A2} = ub8(A), {S, skip_ub4(A2)}
            end,
            {Locator, C} = bytes(B),
            {{lob, DataType, Size, Locator}, C}
    end.

%% JSON and VECTOR come as LOBs with all their data prefetched; the locator
%% is not needed (read_oson, read_vector).
prefetched_lob(Data, Decode) ->
    case ub4(Data) of
        {0, Rest} -> {null, Rest};
        {_Length, A} ->
            B = skip_ub4(skip_ub8(A)),      %size, chunk size
            {Image, C} = bytes(B),
            D = skip_bytes(C),              %LOB locator
            case Image of
                null -> {null, D};
                _ -> {Decode(Image), D}
            end
    end.

%% An object (read_dbobject): its packed bytes, as is.
dbobject(Data) ->
    A = skip_bytes_with_length(skip_bytes_with_length(Data)),  %type OID, OID
    B = skip_ub2(skip_bytes_with_length(A)),  %snapshot, version
    {Length, C} = ub4(B),
    D = skip_ub2(C),                        %flags
    case Length of
        0 -> {null, D};
        _ -> {Bin, E} = bytes(D), {to_list(Bin), E}
    end.

%% Helpers

repeat(0, _Fun, Data) -> Data;
repeat(Num, Fun, Data) -> repeat(Num - 1, Fun, Fun(Data)).

repeat_acc(Num, Fun, Data) ->
    repeat_acc(Num, lists:duplicate(Num, x), fun(X, _) -> Fun(X) end, Data).

repeat_acc(_Num, Items, Fun, Data) ->
    {Values, Rest} = lists:foldl(fun(Item, {Acc, X}) ->
        {Value, X2} = Fun(X, Item),
        {[Value|Acc], X2}
    end, {[], Data}, Items),
    {lists:reverse(Values), Rest}.

nullable(null) -> <<>>;
nullable(Bin) -> Bin.

to_list(null) -> [];
to_list(Bin) -> binary_to_list(Bin).
