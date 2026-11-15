%% Encoding the TNS packets and the TTC messages of the requests, after the
%% Message classes of python-oracledb thin mode (thin/messages/*.pyx). The
%% fields of the messages depend on the negotiated capabilities (#caps{}).
-module(orax_tns_encoder).

%% API
-export([encode_packet/3, encode_packet/4]).
-export([encode_record/2]).
-export([encode_str/1]).
-export([encode_helper/2]).
-export([bind_format/2, value_bytes/2]).

-include("orax.hrl").

%% API
encode_packet(Type, Data, Length) ->
    encode_packet(Type, Data, Length, 0).

%% Packets take a 32-bit length once TNS version 315 or later is negotiated.
%% The end of the data (eof) is a data packet with only the EOF data flag.
encode_packet(eof, _Data, _Length, Version) ->
    {<<(packet_header(10, ?TNS_DATA, Version))/binary, ?TNS_DATA_FLAGS_EOF:16>>, <<>>};
encode_packet(?TNS_DATA, Data, Length, Version) ->
    PacketSize = byte_size(Data) + 10,
    BodySize = Length - 10,
    case Data of
        <<PacketBody:BodySize/binary, Rest/bits>> when PacketSize > Length ->
            {<<(packet_header(Length, ?TNS_DATA, Version))/binary, 32:16, PacketBody/binary>>, Rest};
        _ ->  {<<(packet_header(PacketSize, ?TNS_DATA, Version))/binary, 0:16, Data/binary>>, <<>>}
    end;
encode_packet(Type, Data, _Length, Version) ->
    PacketSize = byte_size(Data) + 8,
    {<<(packet_header(PacketSize, Type, Version))/binary, Data/binary>>, <<>>}.

packet_header(Size, Type, Version) when Version >= 315 ->
    <<Size:32, Type:8, 0:8, 0:16>>;
packet_header(Size, Type, _Version) ->
    <<Size:16, 0:16, Type:8, 0:8, 0:16>>.

encode_record(description, EnvOpts) ->
    {ok, UserHost}  = inet:gethostname(),
    User            = proplists:get_value(user, EnvOpts),
    Host            = proplists:get_value(host, EnvOpts, ?DEF_HOST),
    Port            = proplists:get_value(port, EnvOpts, ?DEF_PORT),
    Sid             = proplists:get_value(sid, EnvOpts, ?DEF_SID),
    ServiceName     = proplists:get_value(service_name, EnvOpts),
    AppName         = proplists:get_value(app_name, EnvOpts, "orax"),
    SslOpts         = proplists:get_value(ssl, EnvOpts, []),
    encode_str(
    "(DESCRIPTION=(CONNECT_DATA=("++ case ServiceName of
        undefined -> "SID="++Sid;
                _ -> "SERVICE_NAME="++ServiceName end ++
    ")(CID=(PROGRAM="++AppName++
    ")(HOST="++UserHost++")(USER="++User++
    ")))(ADDRESS=(PROTOCOL="++ case SslOpts of
               [] -> "TCP";
                _ -> "TCPS" end ++
    ")(HOST="++Host++")(PORT="++integer_to_list(Port)++")))");
%% Version 319 lets 23ai and later servers mark the end of each response;
%% from 315 on, packet lengths take 32 bits and the SDU is sent in 32 bits too.
%% Returns the connect packet body and the connect data to send after it in a
%% data packet: the server takes at most 230 bytes of connect data inside the
%% connect packet (the header still declares the whole length).
encode_record(login, #oraclient{env=EnvOpts,sdu=Sdu,auth=Desc}) ->
    Data = if Desc =/= [] -> encode_str(Desc); true -> encode_record(description, EnvOpts) end,
    Connect = <<
    ?TNS_VERSION_DESIRED:16, % Packet version number
    1,57,                    % Lowest compatible version number
    0,0,                     % Global service options supported
    (min(Sdu, 65535)):16,    % SDU
    255,255,                 % TDU
    79,152,                  % Protocol Characteristics
    0,0,                     % Max packets before ACK
    0,1,                     % 1 in hardware byte order
    (byte_size(Data)):16,    % Connect Data length
    0,74,                    % Connect Data offset
    0,0,0,0,                 % Max connect data that can be received
    132,132,                 % ANO disabled
    0:192,
    Sdu:32,                  % SDU (large)
    Sdu:32,                  % TDU (large)
    0:32,                    % Connect flags 1
    0:32                     % Connect flags 2
    >>,
    case byte_size(Data) > ?TNS_MAX_CONNECT_DATA of
        true -> {Connect, Data};
        false -> {<<Connect/binary, Data/binary>>, <<>>}
    end;
encode_record(sess, #oraclient{env=EnvOpts} = State) ->
    {ok, UserHost}  = inet:gethostname(),
    UserPID         = os:getpid(),
    User            = proplists:get_value(user, EnvOpts),
    Role            = proplists:get_value(role, EnvOpts, 0),
    Prelim          = proplists:get_value(prelim, EnvOpts, 0),
    AppName         = proplists:get_value(app_name, EnvOpts, "orax"),
    User2 = encode_str(User),
    <<
    (function_code(?TTI_SESS, State))/binary,
    1,                                                                         %authusr
    (encode_sb2(byte_size(User2)))/binary,
    (encode_sb2((Role * 32) bor (Prelim * 128) bor 1))/binary,                 %auth mode
    1,                                                                         %authivl
    (encode_sb2(5))/binary,                                                    %number of keyval pairs
    1,1,                                                                       %authovl
    (raw_bytes_and_length(User2))/binary,
    (encode_keyval("AUTH_TERMINAL", "unknown"))/binary,
    (encode_keyval("AUTH_PROGRAM_NM", AppName))/binary,
    (encode_keyval("AUTH_MACHINE", UserHost))/binary,
    (encode_keyval("AUTH_PID", UserPID))/binary,
    (encode_keyval("AUTH_SID", User))/binary
    >>;
encode_record(auth, #oraclient{env=EnvOpts,passwd=Passwd,req=Request} = State) ->
    User            = proplists:get_value(user, EnvOpts),
    ProxyUser       = proplists:get_value(proxy_user, EnvOpts, []),
    Role            = proplists:get_value(role, EnvOpts, 0),
    Prelim          = proplists:get_value(prelim, EnvOpts, 0),
    Passwd ! {get, self()},
    {Pass, NewPass} = receive Reply -> Reply end,
    User2 = encode_str(User),
    Pass2 = binary_to_list(encode_str(Pass)),
    NewPass2 = binary_to_list(encode_str(NewPass)),
    #logon{auth=AuthSess, speedy_key=SpeedyKey, key=KeyConn, password=AuthPass, newpassword=AuthNewPass} =
    orax_crypt:generate(Request#logon{user=binary_to_list(User2), password=Pass2, newpassword=NewPass2}),
    {PassMode, PassInd} = if AuthNewPass =/= [] -> {18, 1}; true -> {1, 0} end,
    KeyInd = if SpeedyKey =/= [] -> 1; true -> 0 end,
    ProxyInd = if ProxyUser =/= [] -> 1; true -> 0 end,
    {<<
    (function_code(?TTI_AUTH, State))/binary,
    1,                                                                         %authusr
    (encode_sb2(byte_size(User2)))/binary,
    (encode_sb2((Role * 32) bor (Prelim * 128) bor PassMode bor 256))/binary,  %auth mode
    1,                                                                         %authivl
    (encode_sb2(5 + KeyInd + PassInd + ProxyInd))/binary,                      %number of keyval pairs
    1,1,                                                                       %authovl
    (raw_bytes_and_length(User2))/binary,
    (if ProxyInd =/= 0 -> encode_keyval("PROXY_CLIENT_NAME", ProxyUser); true -> <<>> end)/binary,
    (encode_keyval("AUTH_PASSWORD", AuthPass))/binary,
    (if PassInd =/= 0 -> encode_keyval("AUTH_NEWPASSWORD", AuthNewPass); true -> <<>> end)/binary,
    (if KeyInd =/= 0 -> encode_keyval("AUTH_PBKDF2_SPEEDY_KEY", SpeedyKey); true -> <<>> end)/binary,
    (encode_keyval(<<"AUTH_SESSKEY">>, AuthSess, 1))/binary,
    (encode_keyval("SESSION_CLIENT_CHARSET", "873"))/binary,
    (encode_keyval("SESSION_CLIENT_DRIVER_NAME", "beam"))/binary,
    (encode_keyval("SESSION_CLIENT_VERSION", "186647296"))/binary
    >>,
    KeyConn};
%% The data types message: character sets, the compile time capabilities
%% (with the end of response marker only when the server offered it in the
%% accept packet), the runtime capabilities and the data types table.
encode_record(dty, #oraclient{charset=Charset, eor=Eor, caps=Caps}) ->
    CompileCaps = orax_caps:compile_caps(Caps, Eor),
    RuntimeCaps = orax_caps:runtime_caps(Caps),
    <<
    ?TTI_DTY,
    (encode_ub2(Charset))/binary,                                              %cli in charset
    (encode_ub2(encode_helper(utf16, Charset)))/binary,                        %cli out charset
    (?TNS_ENCODING_MULTI_BYTE bor ?TNS_ENCODING_CONV_LENGTH),                  %encoding flags
    (byte_size(CompileCaps)),
    CompileCaps/binary,
    (byte_size(RuntimeCaps)),
    RuntimeCaps/binary,
    (orax_caps:data_types())/binary
    >>;
encode_record(pro, _State) ->
    <<
    ?TTI_PRO,
    6,0,98,101,97,109,0
    >>;
encode_record(spfp, State) ->
    <<
    (function_code(?TTI_SPFP, State))/binary,
    1,1,100,1,1,0,0,0,0,0
    >>;
encode_record(start, #oraclient{req=Request} = State) ->
    <<
    (function_code(?TTI_STRT, State))/binary,
    (encode_sb4(Request))/binary,   %mode 0 norestrict, 1 restrict, 16 force
    1
    >>;
encode_record(stop, #oraclient{req=Request} = State) ->
    <<
    (function_code(?TTI_STOP, State))/binary,
    (encode_sb4(Request))/binary,   %mode 2 immediate, 4 normal, 8 final, 64 abort, 128 tran
    1
    >>;
encode_record(tran, #oraclient{req=Request} = State) ->
    function_code(Request, State);
%% Fetches more rows of an open cursor (fetch.pyx).
encode_record(fetch, #oraclient{fetch=Fetch,req=Cursor} = State) ->
    <<
    (function_code(?TTI_FETCH, State))/binary,
    (encode_ub4(Cursor))/binary,    %cursor
    (encode_ub4(Fetch))/binary      %rows to fetch
    >>;
encode_record(exec, #oraclient{req=#exec{} = Exec} = State) ->
    execute(Exec, State);
%% Closes the given cursors, before the function that follows.
encode_record(close_cursors, #oraclient{req=Cursors} = State) ->
    <<
    (piggyback_code(?TTI_OCCA, State))/binary,
    1,                                      %pointer
    (encode_ub4(length(Cursors)))/binary,
    << <<(encode_ub4(Cursor))/binary>> || Cursor <- Cursors >>/binary
    >>;
encode_record(close, State) ->
    function_code(?TTI_LOGOFF, State).

%% The header of a function and of a piggyback: the function code, the
%% sequence number and (23.1 ext 1 on) the token number.
function_code(Code, State) ->
    header(?TTI_FUN, Code, State).

piggyback_code(Code, State) ->
    header(?TTI_PFN, Code, State).

header(Type, Code, #oraclient{seq=Seq, caps=Caps}) ->
    Token =
    case Caps of
        #caps{field_version=Version} when Version >= ?TNS_CCAP_FIELD_VERSION_23_1_EXT_1 -> <<0>>;  %ub8 token number
        _ -> <<>>
    end,
    <<Type, Code, Seq, Token/binary>>.

%% Execute

%% The execute message (_write_execute_message): a full execute, which
%% parses the statement when it has no cursor yet, or the define of the
%% columns of a query whose cursor is open.
execute(#exec{cursor_id=CursorId, sql=Sql, kind=Kind, binds=Binds, defines=Defines,
              prefetch=Prefetch, commit=Commit, rows=Rows} = Exec, #oraclient{caps=Caps} = State) ->
    Define = Defines =/= [],
    NumParams = if Define -> 0; true -> length(Binds) end,
    Parse = CursorId =:= 0 orelse Kind =:= ddl,
    Query = Kind =:= query,
    NumExecs = length(Rows),
    Options =
        flag(Define, ?TNS_EXEC_OPTION_DEFINE) bor
        flag(not Define, ?TNS_EXEC_OPTION_EXECUTE) bor
        flag(Parse, ?TNS_EXEC_OPTION_PARSE) bor
        flag(Query andalso Prefetch > 0, ?TNS_EXEC_OPTION_FETCH) bor
        flag(Kind =/= plsql, ?TNS_EXEC_OPTION_NOT_PLSQL) bor
        flag(Kind =:= plsql andalso NumParams > 0, ?TNS_EXEC_OPTION_PLSQL_BIND) bor
        flag(NumParams > 0, ?TNS_EXEC_OPTION_BIND) bor
        flag(Commit, ?TNS_EXEC_OPTION_COMMIT),
    ExecFlags = flag(not Define, ?TNS_EXEC_FLAGS_IMPLICIT_RESULTSET),
    Version = Caps#caps.field_version,
    <<
    (function_code(?TTI_ALL8, State))/binary,
    (encode_ub4(Options))/binary,           %execute options
    (encode_ub4(CursorId))/binary,          %cursor id
    (case Parse of
        true -> <<1, (encode_ub4(byte_size(Sql)))/binary>>;  %pointer (sql), sql length
        false -> <<0, 0>>
    end)/binary,
    1,                                      %pointer (vector)
    (encode_ub4(13))/binary,                %al8i4 array length
    0,                                      %pointer (al8o4)
    0,                                      %pointer (al8o4l)
    0,                                      %prefetch buffer size
    (encode_ub4(Prefetch))/binary,          %prefetch number of rows
    (encode_ub4(?TNS_MAX_LONG_LENGTH))/binary,  %maximum long size
    (case NumParams of
        0 -> <<0, 0>>;                      %pointer (binds), number of binds
        _ -> <<1, (encode_ub4(NumParams))/binary>>
    end)/binary,
    0,                                      %pointer (al8app)
    0,                                      %pointer (al8txn)
    0,                                      %pointer (al8txl)
    0,                                      %pointer (al8kv)
    0,                                      %pointer (al8kvl)
    (case Define of
        true -> <<1, (encode_ub4(length(Defines)))/binary>>;  %pointer (al8doac), number of defines
        false -> <<0, 0>>
    end)/binary,
    0,                                      %registration id (lsb)
    0,                                      %pointer (al8objlist)
    1,                                      %pointer (al8objlen)
    0,                                      %pointer (al8blv)
    0,                                      %al8blvl
    0,                                      %pointer (al8dnam)
    0,                                      %al8dnaml
    0,                                      %registration id (msb)
    0,                                      %pointer (al8pidmlrc)
    0,                                      %al8pidmlrcbl
    0,                                      %pointer (al8pidmlrcl)
    (if Version >= ?TNS_CCAP_FIELD_VERSION_12_2 ->
        <<0,                                %pointer (al8sqlsig)
          0,                                %SQL signature length
          0,                                %pointer (SQL ID)
          0,                                %allocated size of SQL ID
          0>>;                              %pointer (length of SQL ID)
        true -> <<>>
    end)/binary,
    (if Version >= ?TNS_CCAP_FIELD_VERSION_12_2_EXT1 ->
        <<0,                                %pointer (chunk ids)
          0>>;                              %number of chunk ids
        true -> <<>>
    end)/binary,
    (case Parse of
        true -> <<(raw_bytes_and_length(Sql))/binary, (encode_ub4(1))/binary>>;  %al8i4[0] parse
        false -> encode_ub4(0)
    end)/binary,
    (encode_ub4(if Query, CursorId =:= 0 -> 0; Query -> Prefetch; true -> NumExecs end))/binary,  %al8i4[1] execution count
    0,0,0,                                  %al8i4[2..4]
    0,0,                                    %al8i4[5..6] SCN
    (encode_ub4(flag(Query, 1)))/binary,    %al8i4[7] is query
    0,                                      %al8i4[8]
    (encode_ub4(ExecFlags))/binary,         %al8i4[9] execute flags
    0,                                      %al8i4[10] fetch orientation
    0,                                      %al8i4[11] fetch pos
    0,                                      %al8i4[12]
    (case Define of
        true -> column_metadata(Defines, Caps);
        false when NumParams > 0 -> bind_params(Exec, Caps);
        false -> <<>>
    end)/binary
    >>.

flag(true, Flag) -> Flag;
flag(false, _Flag) -> 0.

%% The metadata of the binds, then a row of values for each execution unless
%% they are all return binds (_write_bind_params).
bind_params(#exec{binds=Binds, rows=Rows} = Exec, Caps) ->
    Metadata = column_metadata(Binds, Caps),
    case [B || #format{param=in} = B <- Binds] =/= [] orelse not Exec#exec.returning of
        true ->
            iolist_to_binary([Metadata | [[?TTI_RXD, bind_row(Exec, Row, Caps)] || Row <- Rows]]);
        false ->
            Metadata
    end.

%% The values of a row; in SQL statements the long ones (buffer above the
%% maximum string size) go after all the others (_write_bind_params_row).
bind_row(#exec{binds=Binds, kind=Kind, returning=Returning}, Row, #caps{max_string_size=Max}) ->
    Pairs = [{B, V} || {B, V} <- lists:zip(Binds, Row),
                       not (Returning andalso B#format.param =:= out)],
    case Kind of
        plsql ->
            [value_bytes(B, V) || {B, V} <- Pairs];
        _ ->
            [value_bytes(B, V) || {B, V} <- Pairs, B#format.data_length =< Max] ++
            [value_bytes(B, V) || {B, V} <- Pairs, B#format.data_length > Max]
    end.

%% The metadata of binds and defines (_write_column_metadata).
column_metadata(Formats, #caps{field_version=Version}) ->
    << <<(oac(F, Version))/binary>> || F <- Formats >>.

oac(#format{data_type=DataType0, data_length=BufferSize0, csfrm=Csfrm}, Version) ->
    {DataType, BufferSize} =
    case DataType0 of
        _ when ?IS_ROWID_TYPE(DataType0); DataType0 =:= ?TNS_TYPE_UROWID ->
            {?TNS_TYPE_VARCHAR, ?TNS_MAX_UROWID_LENGTH};
        _ -> {DataType0, BufferSize0}
    end,
    {ContFlag, BufferSize2, PrefetchLength} =
    case DataType of
        _ when ?IS_LOB_TYPE(DataType) -> {?TNS_LOB_PREFETCH_FLAG, BufferSize, 0};
        ?TNS_TYPE_JSON -> {?TNS_LOB_PREFETCH_FLAG, ?TNS_JSON_MAX_LENGTH, ?TNS_JSON_MAX_LENGTH};
        ?TNS_TYPE_VECTOR -> {?TNS_LOB_PREFETCH_FLAG, ?TNS_VECTOR_MAX_LENGTH, ?TNS_VECTOR_MAX_LENGTH};
        _ -> {0, BufferSize, 0}
    end,
    <<
    DataType,
    ?TNS_BIND_USE_INDICATORS,               %flags
    0,                                      %precision
    0,                                      %scale
    (encode_ub4(BufferSize2))/binary,
    0,                                      %max number of array elements
    (encode_ub8(ContFlag))/binary,
    0,                                      %OID
    0,                                      %version
    (encode_ub2_var(if Csfrm =/= 0 -> ?TNS_CHARSET_UTF8; true -> 0 end))/binary,  %character set id
    Csfrm,                                  %character set form
    (encode_ub4(PrefetchLength))/binary,    %max chars (LOB prefetch)
    (if Version >= ?TNS_CCAP_FIELD_VERSION_12_2 -> <<0>>; true -> <<>> end)/binary  %oaccolid
    >>.

%% The metadata of a bind value (OracleMetadata.from_value with the sizes of
%% _finalize_init): text (binaries and strings) as VARCHAR and {raw, Bytes} as
%% RAW, of their length (the largest of the rows), numbers as NUMBER, dates as
%% DATE, TIMESTAMP or TIMESTAMP WITH TIME ZONE. {out, Type} binds take the
%% type of a value of that type; null binds the type of the first value of
%% the rows that is not null (VARCHAR when they all are).
bind_format({out, Type}, Values) ->
    Format =
    case encode_helper(param, Type) of
        [] -> #format{data_type=?TNS_TYPE_VARCHAR, data_length=4000, max_size=4000, csfrm=?CS_FORM_IMPLICIT};
        {raw, <<>>} -> #format{data_type=?TNS_TYPE_RAW, data_length=4000};
        Value -> bind_format(Value, Values)
    end,
    Format#format{param=out};
bind_format({in, Value}, Values) ->
    bind_format(Value, Values);
bind_format(null, Values) ->
    case [V || V <- Values, V =/= null] of
        [] -> varchar(1);
        [Value|_] -> bind_format(Value, Values)
    end;
bind_format(Value, Values) when is_binary(Value); is_list(Value) ->
    varchar(lists:max([0|[byte_size(bin(V)) || V <- Values, is_list(V) orelse is_binary(V)]]));
bind_format({raw, Value}, Values) when is_binary(Value) ->
    Size = lists:max([0|[byte_size(V) || {raw, V} <- Values]]),
    #format{data_type=?TNS_TYPE_RAW, data_length=if Size =:= 0 -> 4000; true -> Size end};
%% A VECTOR has no buffer size of its own (python's DB_TYPE_VECTOR): its oac
%% says 1 MB, but it is not a long value and keeps its place in the row.
bind_format(Value, _Values) when ?IS_VECTOR(Value) ->
    #format{data_type=?TNS_TYPE_VECTOR, data_length=0};
bind_format(Value, _Values) when is_number(Value) ->
    #format{data_type=?TNS_TYPE_NUMBER, data_length=22};
bind_format({{_,_,_}, {_,_,_,_}}, _Values) ->
    #format{data_type=?TNS_TYPE_TIMESTAMP, data_length=11};
bind_format({{_,_,_}, {_,_,_,_}, _}, _Values) ->
    #format{data_type=?TNS_TYPE_TIMESTAMPTZ, data_length=13};
bind_format(Value, _Values) when is_tuple(Value) ->
    #format{data_type=?TNS_TYPE_DATE, data_length=7};
bind_format(clob, _Values) ->
    #format{data_type=?TNS_TYPE_VARCHAR, data_length=33554432, csfrm=?CS_FORM_IMPLICIT};
bind_format(cursor, _Values) ->
    #format{data_type=?TNS_TYPE_REFCURSOR, data_length=4}.

varchar(MaxSize) ->
    #format{data_type=?TNS_TYPE_VARCHAR, data_length=max(MaxSize, 1) * 4,
            max_size=MaxSize, csfrm=?CS_FORM_IMPLICIT}.

bin(V) when is_binary(V) -> V;
bin(V) -> encode_str(V).

%% The bytes of a bind value (_write_bind_params_column).
value_bytes(#format{param=out, data_type=?TNS_TYPE_REFCURSOR}, _Value) ->
    <<1, 0>>;
value_bytes(#format{param=out}, _Value) ->
    <<0>>;
value_bytes(_Format, null) ->
    <<0>>;
value_bytes(_Format, {in, Value}) ->
    value_bytes(_Format, Value);
value_bytes(_Format, {raw, Value}) when is_binary(Value) ->
    raw_bytes_and_length(Value);
value_bytes(#format{data_type=?TNS_TYPE_VECTOR}, Value) ->
    Image = orax_vector:encode(Value),
    <<(qlocator(byte_size(Image)))/binary, (raw_bytes_and_length(Image))/binary>>;
value_bytes(_Format, Value) when is_list(Value); is_binary(Value) ->
    raw_bytes_and_length(bin(Value));
value_bytes(_Format, Value) when is_number(Value) ->
    raw_bytes_and_length(encode_number(Value));
value_bytes(_Format, Value) when is_tuple(Value) ->
    raw_bytes_and_length(encode_date(Value)).

%% The value based locator that goes before the image of a VECTOR or JSON
%% value (write_qlocator): 40 bytes, after their length.
qlocator(DataLength) ->
    <<
    (encode_ub4(40))/binary,                %QLocator length
    40,                                     %chunk length
    38:16,                                  %QLocator length less 2 bytes
    ?TNS_LOB_QLOCATOR_VERSION:16,
    (?TNS_LOB_LOC_FLAGS_VALUE_BASED bor ?TNS_LOB_LOC_FLAGS_BLOB bor ?TNS_LOB_LOC_FLAGS_ABSTRACT),
    ?TNS_LOB_LOC_FLAGS_INIT,
    0:16,                                   %additional flags
    1:16,                                   %byt1
    DataLength:64,
    0:16,                                   %unused
    0:16,                                   %csid
    0:16,                                   %unused
    0:64,                                   %unused
    0:64                                    %unused
    >>.

%% Bytes after their length: up to 252 bytes after a length byte, longer ones
%% in chunks of up to 32767 bytes (ub4 length each) ending with a zero length.
raw_bytes_and_length(Data) when byte_size(Data) =< ?TNS_MAX_SHORT_LENGTH ->
    <<(byte_size(Data)), Data/binary>>;
raw_bytes_and_length(Data) ->
    <<?TNS_LONG_LENGTH_INDICATOR, (chunks(Data))/binary, 0>>.

chunks(<<Chunk:?TNS_CHUNK_SIZE/binary, Rest/binary>>) when Rest =/= <<>> ->
    <<(encode_ub4(?TNS_CHUNK_SIZE))/binary, Chunk/binary, (chunks(Rest))/binary>>;
chunks(Chunk) ->
    <<(encode_ub4(byte_size(Chunk)))/binary, Chunk/binary>>.

%% Integers

%% Integers in universal format, in 1, 2, 4 or 8 bytes after their length
%% (Buffer.write_ub4/write_ub8).
encode_ub4(0) -> <<0>>;
encode_ub4(Data) when Data =< 16#ff -> <<1, Data>>;
encode_ub4(Data) when Data =< 16#ffff -> <<2, Data:16>>;
encode_ub4(Data) -> <<4, Data:32>>.

encode_ub8(Data) when Data =< 16#ffffffff -> encode_ub4(Data);
encode_ub8(Data) -> <<8, Data:64>>.

encode_ub2_var(Data) -> encode_ub4(Data).

encode_keyval(Key, Value) ->
    encode_keyval(list_to_binary(Key), encode_str(Value), 0).

encode_keyval(Key, Value, Data) ->
    KeyLen = byte_size(Key),
    ValueLen = byte_size(Value),
    BinKey = if KeyLen =/= 0 -> <<(encode_sb4(KeyLen))/binary, (encode_len(Key))/binary>>; true -> <<0>> end,
    BinValue = if ValueLen =/= 0 -> <<(encode_sb4(ValueLen))/binary, (encode_len(Value))/binary>>; true -> <<0>> end,
    <<BinKey/binary, BinValue/binary, (encode_sb4(Data))/binary>>.

encode_len(Data) ->
    Length = byte_size(Data),
    <<Length, Data:Length/binary>>.

encode_ub2(Data) ->
    <<Data:16/little>>.

encode_sb2(Data) ->
    encode_sb4(Data).

encode_sb4(0) -> <<0>>;
encode_sb4(Data) ->
    <<F,S,T,L>> = <<Data:32>>,
    case F of
        0 -> case S of
            0 -> case T of
                0 -> <<1,L>>;
                _ -> <<2,T,L>>
                end;
            _ -> <<3,S,T,L>>
            end;
        _ -> <<4,F,S,T,L>>
    end.

encode_str(Data) ->
    try list_to_binary(Data) of    %latin-1
        Bin -> Bin
    catch
        error:_ -> unicode:characters_to_binary(Data)
    end.

%% Values

encode_number(+0.0) -> <<128>>;
encode_number(0) -> <<128>>;
encode_number(Data) when is_integer(Data) ->
    list_to_binary([<<B>> || B <- lnxfmt(lnxmin(abs(Data),1,[]), Data)]);
encode_number(Data) when is_float(Data) ->
    list_to_binary([<<B>> || B <- lnxfmt(lnxren(abs(Data),0), Data)]).

lnxmin(N, I, Acc) when N div 100 =:= 0 ->
    lnxpak(lists:reverse([I-1|[N rem 100|Acc]]));
lnxmin(N, I, Acc) when I < 20 ->
    lnxmin(N div 100, I+1, [N rem 100|Acc]).

lnxren(N,I) when N < 1.0 ->
    lnxren(N * 100.0,I-1);
lnxren(N,I) when 1.0 =< N, N < 10.0 ->
    lnxpak(lists:reverse([I|lnxren(N,0,1,[])]));
lnxren(N,I) when 10.0 =< N, N < 100.0 ->
    lnxpak(lists:reverse([I|lnxren(N,0,0,[])]));
lnxren(N,I) when N >= 100.0 ->
    lnxren(N * 0.01,I+1).

lnxren(_N, I, 0, [H|L]) when I =:= 8 ->
    lists:reverse(lnxpak([(H+5) div 10 * 10|L],1));
lnxren(_N, I, 1, [H|L]) when I =:= 8 ->
    lists:reverse(lnxpak([H+(H div 50)|L],1));
lnxren(N, I, J, Acc) when I < 8 ->
    lnxren((N-trunc(N))*100.0, I+1, J, [trunc(N)|Acc]).

lnxpak([0|L])->
    lnxpak(L);
lnxpak(L)->
    lists:reverse(L).

lnxpak([100],I) when I =:= 8 ->
    [100-1];
lnxpak([100|[H|L]],I) when I < 8 ->
    lnxpak([H+1|L],I+1);
lnxpak(L,_I) ->
    L.

lnxfmt([I|L], Data) when Data > 0 ->
    [(I+192+1)|[ N+1 || N <- L]];
lnxfmt([I|L], Data) when Data < 0 ->
    [(I+192+1 bxor 255)|[ 101-N || N <- L]]++[102].

%% DATE (7 bytes), TIMESTAMP (11 bytes; 7 when the fractional seconds are
%% zero, as the protocol requires) and TIMESTAMP WITH TIME ZONE (13 bytes).
encode_date({{Year,Mon,Day}, {Hour,Min,Sec}}) ->
    <<
    (Year div 100 + 100),
    (Year rem 100 + 100),
    (Mon),
    (Day),
    (Hour + 1),
    (Min + 1),
    (Sec + 1)
    >>;
encode_date({{Year,Mon,Day}, {Hour,Min,Sec,0}}) ->
    encode_date({{Year,Mon,Day}, {Hour,Min,Sec}});
encode_date({{Year,Mon,Day}, {Hour,Min,Sec,Ms}}) ->
    <<(encode_date({{Year,Mon,Day}, {Hour,Min,Sec}}))/binary, (Ms * 1000):4/integer-unit:8>>;
encode_date({Year,Mon,Day}) when is_integer(Year)  ->
    encode_date({{Year,Mon,Day}, {0,0,0}});
encode_date({{Year,Mon,Day}, {Hour,Min,Sec,Ms}, Offset}) when is_integer(Offset) ->
    Secs = calendar:datetime_to_gregorian_seconds({{Year,Mon,Day}, {Hour,Min,Sec}}),
    {D, T} = calendar:gregorian_seconds_to_datetime(Secs - Offset),
    {H, M} = {(Offset div 3600 + 20), (Offset rem 3600 div 60 + 60)},
    <<(timestamp(D, T, Ms))/binary,H,M>>;
encode_date({{Year,Mon,Day}, {Hour,Min,Sec,Ms}, Data}) when is_list(Data) ->
    Zoneid = get_key(list_to_binary(Data), ?ZONEIDMAP),
    {H, M} = {((Zoneid band 8128) bsr 6) bor 128, ((Zoneid band 63) bsl 2)},
    <<(timestamp({Year,Mon,Day}, {Hour,Min,Sec}, Ms))/binary,H,M>>.

timestamp(D, T, Ms) ->
    <<(encode_date({D, T}))/binary, (Ms * 1000):32>>.

get_key(Data, [{Key, {_,Value}} | M]) ->
    case binary:match(Data,list_to_binary(Value)) of
        nomatch -> get_key(Data, M);
        _ -> Key
    end;
get_key(Data, [_|M]) -> get_key(Data, M);
get_key(_Data, []) -> 28.

encode_helper(param, Data) ->
    Values =
    [
    {number, 0}, {integer, 0}, {float, 0}, {decimal, 0},
    {varchar, []}, {char, []}, {nvarchar, []}, {nchar, []}, {string, []}, {hexstring, []},
    {clob, clob}, {nclob, clob},
    {raw, {raw, <<>>}}, {blob, {raw, <<>>}}, {binary, {raw, <<>>}},
    {vector, {float32, []}},
    {date, {1900,1,1}}, {timestamp, {{1900,1,1}, {0,0,0,0}}}, {timestamptz, {{1900,1,1}, {0,0,0,0}, 0}}
    ],
    proplists:get_value(Data, Values, Data);
encode_helper(utf16, Data) ->
    case lists:member(Data, [?AL16UTF16_CHARSET,830,832,837,838,846,852,860,865,867,868]) of
        false -> Data;
        true -> ?UTF8_CHARSET
    end;
encode_helper(sess, _L) ->
    Secs = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    USecs = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
    "ALTER SESSION SET TIME_ZONE='"++orax_values:tz_offset((Secs - USecs) div 3600, 0)++"'".
