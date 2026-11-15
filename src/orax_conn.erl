-module(orax_conn).

%% API
-export([connect/1, connect/2]).
-export([reconnect/1]).
-export([disconnect/1, disconnect/2]).
-export([sql_query/2, sql_query/3]).

-include("orax.hrl").

-opaque state() :: #oraclient{}.
-type error_type() :: socket | remote | local.
-type columns() :: list().
-type metainfo() :: list().
-type rows() :: list().
-type return_status() :: non_neg_integer().
-type out_params() :: list().
-type empty_result() :: {ok, state()} | {error, error_type(), binary(), state()}.
-type fetched_rows() :: {fetched_rows, non_neg_integer(), metainfo(), rows()}.
-type affected_rows() :: {affected_rows, non_neg_integer()}.
-type result_set() :: {result_set, columns(), metainfo(), rows()}.
-type procedure_result() :: {proc_result, return_status(), out_params() | metainfo()}.
-type result() :: fetched_rows() | affected_rows() | result_set() | procedure_result().
-type query_result() :: {ok, [result()], state()}.
-type options() :: [env()].

-export_type([state/0]).
-export_type([options/0]).

%% API
-spec connect([env()]) -> empty_result().
connect(Opts) ->
    Tout        = proplists:get_value(timeout, Opts, ?DEF_TIMEOUT),
    connect(Opts, Tout).

-spec connect([env()], timeout()) -> empty_result().
connect(Opts, Tout) ->
    Host        = proplists:get_value(host, Opts, ?DEF_HOST),
    Port        = proplists:get_value(port, Opts, ?DEF_PORT),
    SslOpts     = proplists:get_value(ssl, Opts, []),
    SocketOpts  = proplists:get_value(socket_options, Opts, []),
    Auto        = proplists:get_value(autocommit, Opts, ?DEF_AUTOCOMMIT),
    Fetch       = proplists:get_value(fetch, Opts, ?DEF_FETCH),
    Sdu         = proplists:get_value(sdu, Opts, ?DEF_SDU),
    Cset        = proplists:get_value(charset, Opts, utf8),
    Charset     = proplists:get_value(Cset, ?CHARSET, ?UTF8_CHARSET),
    SockOpts = [binary, {active, false}, {packet, raw},
            {nodelay, true}, {keepalive, true}]++SocketOpts,
    Desc        = proplists:get_value(description, Opts, []),
    Pass        = proplists:get_value(password, Opts),
    NewPass     = proplists:get_value(newpassword, Opts, []),
    EnvOpts     = proplists:delete(password, proplists:delete(newpassword, Opts)),
    Passwd = spawn(fun() -> loop({Pass, NewPass}) end),
    case gen_tcp:connect(Host, Port, SockOpts, Tout) of
        {ok, Socket} ->
            {ok, Socket2} = sock_connect(Socket, SslOpts, Tout),
            {ok, [{recbuf, RecBuf}]} = sock_getopts(Socket2, [recbuf]),
            sock_setopts(Socket2, [{buffer, RecBuf}]),
            State = #oraclient{socket=Socket2, env=EnvOpts, passwd=Passwd, auth=Desc,
            auto=Auto, fetch=Fetch, sdu=Sdu, charset=Charset, timeouts={Tout, deadline(Tout)}},
            {ok, State2} = send_req(login, State),
            handle_login(State2#oraclient{conn_state=auth_negotiate});
        {error, Reason} ->
            handle_error(socket, Reason, #oraclient{})
    end.

-spec disconnect(state()) -> {ok, [env()]}.
disconnect(#oraclient{socket=Socket, env=Env, passwd=Passwd}) ->
    sock_close(Socket),
    freeval(Passwd),
    {ok, Env}.

-spec disconnect(state(), timeout()) -> {ok, []}.
disconnect(#oraclient{socket=Socket, passwd=Passwd} = State, _Tout) ->
    send_req(close, State),
    sock_close(Socket),
    freeval(Passwd),
    {ok, []}.

-spec reconnect(state()) -> empty_result().
reconnect(#oraclient{passwd=Passwd} = State) ->
    Passwd ! {get, self()},
    {Pass, NewPass} = receive Reply -> Reply end,
    {ok, EnvOpts} = disconnect(State),
    Pass2 = if NewPass =/= [] -> NewPass; true -> Pass end,
    connect([{password, Pass2}|EnvOpts]).

%% The call timeout bounds the whole call, every round trip included. When it
%% expires the call is broken off and {error, timeout, ...} is returned; the
%% connection stays usable unless the server does not answer the break.
-spec sql_query(state(), string() | tuple(), timeout()) -> query_result().
sql_query(#oraclient{timeouts={_Tout, Deadline}} = State, Query, Tout) ->
    sql_query(State#oraclient{timeouts={Tout, Deadline}}, Query).

-spec sql_query(state(), string() | tuple()) -> query_result().
sql_query(#oraclient{timeouts={Tout, _Deadline}} = State, Query) ->
    query(State#oraclient{timeouts={Tout, deadline(Tout)}, break=false}, Query).

query(State, Query) when is_list(Query) ->
    query(State, {Query, []});
query(State, {Query, Bind}) when length(Query) > 10 ->
    query(State, {Query, Bind, [], []});
query(State, {batch, Query, [Bind|Batch]}) ->
    query(State, {Query, Bind, Batch, []});
query(State, {fetch, Query, Bind}) ->
    query(State, {Query, Bind, [], fetch});
query(#oraclient{conn_state=connected} = State, {fetch, Cursor, RowFormat, LastRow}) ->
    {ok, State2} = send_req(fetch, State#oraclient{type=fetch}, Cursor),
    handle_resp({Cursor, RowFormat, [LastRow]}, State2);
query(#oraclient{conn_state=connected} = State, {Query, Bind, Batch, Fetch}) ->
    {ok, State2} = send_req(exec, State, {Query, Bind, Batch}),
    #oraclient{defcols=DefCol, params=RowFormat, type=Type} = State2,
    handle_resp(get_param(defcols, {DefCol, RowFormat, Type}),
    State2#oraclient{type=get_param(type, {Type, Fetch})});
query(#oraclient{conn_state=connected, timeouts={_Tout, Deadline}} = State, {Query, Bind}) ->
    case lists:nth(1, string:tokens(string:to_upper(Query)," \t;")) of
        "SESSION" -> query(State, {?ENCODER:encode_helper(sess, []), [], [], []});
        "COMMIT" -> handle_req(tran, State, ?TTI_COMMIT);
        "ROLLBACK" -> handle_req(tran, State, ?TTI_ROLLBACK);
        %% Autocommit is the commit-on-success option sent with each execute;
        %% the legacy TTI_COMON/TTI_COMOFF calls fail on recent servers
        %% (ORA-03154), so only the client-side flag is switched.
        "COMON" -> {ok, [], State#oraclient{auto=1}};
        "COMOFF" -> {ok, [], State#oraclient{auto=0}};
        "PING" -> handle_req(tran, State, ?TTI_PING);
        "STOP" -> handle_req(stop, State, hd(Bind));
        "START" ->
            State2 = state_of(handle_req(spfp, State, []), State),
            handle_req(start, State2, hd(Bind));
        "CLOSE" -> send_req(close, State), handle_error(local, [], State);
        "CURRESET" -> {ok, [], state_of(send_req(reset, State), State)};
        "TIMEOUT" -> {ok, [], State#oraclient{timeouts={hd(Bind), Deadline}}};
        "FETCH" -> {ok, [], State#oraclient{fetch=hd(Bind)}};
        _ -> {ok, undefined, State}
    end.

loop(Values) ->
    receive {get, From} -> From ! Values, loop(Values); {set, Values2} -> loop(Values2) end.

%% internal
handle_login(State) ->
    case recv_packet(State) of
        {ok, ?TNS_DATA, _Flags, Payload, State2} ->
            case resp_packet(?TNS_DATA, Payload, {decoding, {<<>>, login}}, login, State2) of
                {ok, Result, State3} -> handle_token(Result, State3);
                Error -> Error
            end;
        {ok, ?TNS_RESEND, _Flags, _Payload, #oraclient{socket=Socket, env=Env, timeouts=Touts} = State2} ->
            {ok, Socket2} = sock_renegotiate(Socket, Env, Touts),
            {ok, State3} = send_req(login, State2#oraclient{socket=Socket2, buf = <<>>}),
            handle_login(State3);
        {ok, ?TNS_ACCEPT, _Flags, Payload, #oraclient{env=Env} = State2} ->
            {Version, Sdu, Flags2} = accept_params(Payload),
            %% the server marks the end of responses once the data types
            %% message has asked for it in the compile time capabilities
            Eor = Version >= ?TNS_VERSION_MIN_END_OF_RESPONSE
                andalso Flags2 band ?TNS_ACCEPT_FLAG_HAS_END_OF_RESPONSE =/= 0
                andalso proplists:get_value(end_of_response, Env, true)
                andalso offered,
            Task = spawn(fun() -> loop(0) end),
            {ok, State3} = send_req(pro, State2#oraclient{seq=Task, sdu=Sdu, version=Version, eor=Eor}),
            handle_login(State3);
        {ok, ?TNS_MARKER, _Flags, Payload, State2} ->
            case resp_packet(?TNS_MARKER, Payload, {decoding, {<<>>, []}}, [], State2) of
                {ok, Result, State3} -> handle_result(Result, [], State3);
                Error -> Error
            end;
        {ok, ?TNS_REDIRECT, _Flags, <<Length:16, Data/binary>>, #oraclient{env=Env} = State2} ->
            case redirect_data(Length, Data, State2) of
                {ok, Data2, State3} ->
                    {ok, Opts} = ?DECODER:decode_token(net, {Data2, Env}),
                    reconnect(State3#oraclient{env=Opts});
                {error, timeout, State3} ->
                    handle_error(socket, timeout, State3);
                Error -> Error
            end;
        {ok, ?TNS_REFUSE, _Flags, <<_Bin:16,_Length:16,Rest/bits>>, State2} ->
            handle_error(local, binary_to_list(Rest), State2);
        {ok, Type, _Flags, _Payload, State2} ->
            handle_error(socket, {unexpected_packet, Type}, State2);
        {error, timeout, State2} ->
            handle_error(socket, timeout, State2);
        Error ->
            Error
    end.

%% Version, options, SDU, TDU, byte order, data length and offset, flags 1,
%% then (version 315 on) the 32-bit SDU and (version 318 on) flags 2.
accept_params(<<Version:16, _Opts:16, _Sdu:16, _:8/binary, _Flags1, _:9/binary, Sdu:32, Rest/binary>>)
  when Version >= ?TNS_VERSION_MIN_LARGE_SDU ->
    Flags2 =
    case Rest of
        <<_:5/binary, Flags:32, _/binary>> when Version >= ?TNS_VERSION_MIN_OOB_CHECK -> Flags;
        _ -> 0
    end,
    {Version, Sdu, Flags2};
accept_params(<<Version:16, _Opts:16, Sdu:16, _/binary>>) ->
    {Version, Sdu, 0}.

%% The redirect packet holds the length of the redirect data, which follows
%% in the same packet or in the next data packet.
redirect_data(Length, Data, State) when byte_size(Data) >= Length ->
    {ok, Data, State};
redirect_data(_Length, _Data, State) ->
    case recv_packet(State) of
        {ok, ?TNS_DATA, _Flags, <<_DataFlags:16, Data/binary>>, State2} -> {ok, Data, State2};
        {ok, Type, _Flags, _Payload, State2} -> handle_error(socket, {unexpected_packet, Type}, State2);
        Error -> Error
    end.

%% The field version is the lower of the client's and the server's.
handle_token({pro, {ServerCaps, _RuntimeCaps}}, State) ->
    FieldVersion =
    case ServerCaps of
        <<_:?TNS_CCAP_FIELD_VERSION/binary, Version, _/binary>> -> min(?TNS_CCAP_FIELD_VERSION_MAX, Version);
        _ -> ?TNS_CCAP_FIELD_VERSION_11_2
    end,
    {ok, State2} = send_req(dty, State#oraclient{field_version=FieldVersion}),
    handle_login(State2);
handle_token(dty, #oraclient{eor=Eor} = State) ->
    {ok, State2} = send_req(sess, State),
    handle_login(State2#oraclient{eor=Eor =:= offered});
handle_token({?TTI_SESS, Request}, State) ->
    {ok, State2} = send_req(auth, State#oraclient{req=Request}),
    handle_login(State2);
handle_token({?TTI_AUTH, Resp, Ver, SessId}, #oraclient{auth=KeyConn} = State) ->
    Cursors = spawn(fun() -> loop([]) end),
    case orax_crypt:validate(#logon{auth=Resp, key=KeyConn}) of
        ok -> {ok, State#oraclient{conn_state=connected,auth=SessId,server=Ver,cursors=Cursors}};
        error -> handle_error(remote, Resp, State)
    end;
handle_token(Result, State) ->       %error
    handle_result(Result, [], State).

handle_error(remote, Reason, State) ->
    {error, remote, Reason, State};
handle_error(socket, Reason, State) ->
    disconnect(State),
    {error, socket, Reason, State#oraclient{conn_state=disconnected}};
handle_error(local, Reason, State) ->
    disconnect(State),
    {ok, Reason, State#oraclient{conn_state=disconnected}}.

handle_bind(Query, Bind) ->
    Ks = string:tokens(Query," \t\r\n;,()="),
    {X, Y} = ?ENCODER:encode_helper(type, string:to_upper(hd(Ks))),
    handle_bind(X, Y, lists:filtermap(fun(L) -> if hd(L) =:= $: -> {true, tl(L)}; true -> false end end, Ks), Bind).

handle_bind(Select, Change, Data, Bind) when is_list(Bind) ->
    try lists:map(fun(L) -> list_to_integer(L) end, Data) of
        Bs -> {Select, Change, lists:map(fun(I) -> lists:nth(I, Bind) end, Bs)}
    catch
        error:_ -> {Select, Change, Bind}
    end;
handle_bind(Select, Change, Data, Bind) when is_map(Bind) ->
    {Select, Change, lists:map(fun(L) -> maps:get(list_to_atom(L), Bind) end, Data)}.

handle_req(pig, #oraclient{cursors=Cursors,seq=Task} = State, {Type, Request}) ->
    {LPig, LPig2} = unzip([get_param(defcols, DefCol) || DefCol <- get_result(Cursors)]),
    Pig = if LPig =/= [] -> get_record(pig, [], {?TTI_CANA, LPig}, Task); true -> <<>> end,
    Pig2 = if LPig2 =/= [] -> get_record(pig, [], {?TTI_OCCA, LPig2}, Task); true -> <<>> end,
    Data = get_record(Type, [], Request, Task),
    handle_req(State, ?TNS_DATA, <<Pig/binary, Pig2/binary, Data/binary>>, []);
handle_req(fob, State, Acc) ->
    handle_req(State, ?TNS_DATA, <<?TTI_FOB>>, Acc);
handle_req(Type, #oraclient{seq=Task} = State, Request) ->
    Data = get_record(Type, [], Request, Task),
    handle_req(State, ?TNS_DATA, Data, []).

handle_req(State, PacketType, Data, Acc) ->
    case send(State, PacketType, Data) of
        {ok, State2} -> handle_resp(Acc, State2);
        Result -> Result
    end.

unzip(Ts) -> unzip(Ts, [], []).

unzip([{X, 0} | Ts], Xs, Ys) -> unzip(Ts, [X | Xs], Ys);
unzip([{X, Y} | Ts], Xs, Ys) -> unzip(Ts, [X | Xs], [Y | Ys]);
unzip([], Xs, Ys) -> {Ys, Ys ++ Xs}.

send_req(login, State) ->
    {Connect, Data} = get_record(login, State, [], 0),
    case send(State, ?TNS_CONNECT, Connect) of
        {ok, State2} -> send(State2, ?TNS_DATA, Data);
        Error -> Error
    end;
send_req(auth, #oraclient{req=Request,seq=Task} = State) ->
    {Data, KeyConn} = get_record(auth, State, Request, Task),
    send(State#oraclient{auth=KeyConn,req=[]}, ?TNS_DATA, Data);
send_req(close, #oraclient{server=0,seq=Task} = State) ->
    freeval(Task),
    send(State, ?TNS_DATA, <<64>>);
send_req(close, #oraclient{auto=0} = State) ->
    _ = handle_req(tran, State, ?TTI_ROLLBACK),
    send_req(close, State#oraclient{auto=1});
send_req(close, #oraclient{cursors=Cursors} = State) ->
    _ = handle_req(pig, State, {close, 0}),
    freeval(Cursors),
    send_req(close, State#oraclient{server=0});
send_req(reset, #oraclient{cursors=Cursors} = State) ->
    Result = handle_req(pig, State, {tran, ?TTI_PING}),
    Cursors ! {set, []},
    Result;
send_req(Type, #oraclient{req=Request,seq=Task} = State) ->
    Data = get_record(Type, State, Request, Task),
    send(State, ?TNS_DATA, Data).

send_req(fetch, #oraclient{seq=Task} = State, {Cursor, RowFormat}) ->
    Data = get_record(exec, State#oraclient{type=fetch}, {Cursor, [], [], [], RowFormat}, Task),
    send(State, ?TNS_DATA, Data);
send_req(fetch, #oraclient{seq=Task} = State, Cursor) ->
    Data = get_record(fetch, State, Cursor, Task),
    send(State, ?TNS_DATA, Data);
send_req(exec, #oraclient{charset=Charset,fetch=Fetch,cursors=Cursors,seq=Task} = State, {Query, Bind, Batch}) ->
    {Select, Change, Bind2} = handle_bind(Query, Bind),
    {Type, Fetch2} = get_param(type, {Select, Change, [B || {out, B} <- Bind2], Fetch}),
    %% Cached cursors keep the bind metadata of their first execution, so the
    %% bind types are part of the key: a statement executed with other types
    %% (e.g. NULL, then RAW) gets its own cursor instead of misread values.
    BindMeta = << <<(?ENCODER:encode_token(oac, get_param(data, B), #format{charset=Charset}))/binary>> || B <- Bind2 >>,
    Sum = erlang:crc32(erlang:crc32(?ENCODER:encode_str(Query)), BindMeta),
    DefCol = get_param(defcols, {Sum, Cursors}),
    {LCursor, Cursor} = get_param(defcols, DefCol),
    Pig = if Cursor =/= 0 -> get_record(pig, [], {?TTI_CANA, [Cursor]}, Task); true -> <<>> end,
    Pig2 = if Cursor =/= 0 -> get_record(pig, [], {?TTI_OCCA, [Cursor]}, Task); true -> <<>> end,
    Data = get_record(exec, State#oraclient{type=Type,fetch=Fetch2}, {LCursor, if LCursor =:= 0 -> Query; true -> [] end,
        [get_param(data, B) || B <- Bind2], Batch, []}, Task),
    send(State#oraclient{type=Type,defcols=DefCol,params=[get_param(format, B, #format{charset=Charset}) || B <- Bind2]},
        ?TNS_DATA, <<Pig/binary, Pig2/binary, Data/binary>>).

handle_resp(Acc, State) ->
    case recv_resp(Acc, State) of
        {ok, Result, State2} -> handle_result(Result, Acc, State2);
        Error -> Error
    end.

handle_result(Result, Acc, #oraclient{type=Type, cursors=Cursors} = State) ->
    case Result of
        {0, _RowNumber, Cursor, {LCursor, RowFormat}, []} when Type =/= change, RowFormat =/= [] ->
            Type2 = if LCursor =:= Cursor -> Type; true -> cursor end,
            {ok, State2} = send_req(fetch, State, {Cursor, RowFormat}),
            #oraclient{defcols=DefCol} = State2,
            {_, DefCol2} = currval(DefCol, {LCursor, Cursor, RowFormat}, Cursors),
            handle_resp({Cursor, RowFormat, []}, State2#oraclient{defcols=DefCol2, type=Type2});
        {RetCode, RowNumber, Cursor, {LCursor, RowFormat}, Rows} ->
            case get_result(Type, RetCode, RowNumber, RowFormat, Rows) of
                more when Type =:= fetch ->
                    {ok, [{fetched_rows, Cursor, RowFormat, Rows}], State};
                more ->
                    {ok, State2} = send_req(fetch, State, Cursor),
                    handle_resp({Cursor, RowFormat, Rows}, State2);
                {ok, Result2} ->
                    #oraclient{defcols=DefCol} = State,
                    State2 =
                    case currval(DefCol, {LCursor, Cursor, RowFormat}, Cursors) of
                        {reset, _} -> state_of(send_req(reset, State), State);
                        _ -> State
                    end,
                    {ok, Result2, State2};
                {error, Result2} ->
                    State2 =
                    case get_result(Cursors) of
                        [] -> State;
                        _ -> state_of(send_req(reset, State), State)
                    end,
                    {ok, Result2, State2}
            end;
        {ok, Result2} -> %tran
            {ok, Result2, State};
        {error, fob} -> %return
            handle_req(fob, State, Acc);
        {error, Reason} ->
            handle_error(remote, Reason, State)
    end.

state_of({ok, State}, _State) -> State;
state_of({ok, _Result, State}, _State) -> State;
state_of({error, _Type, _Reason, State}, _State) -> State;
state_of(_Result, State) -> State.

get_result(cursor, 0, _RowNumber, _RowFormat, _Rows) ->
    more;
get_result(cursor, 1405, _RowNumber, _Reason, Rows) ->
    {error, [{proc_result, 1405, Rows}]};
get_result(change, 0, RowNumber, _RowFormat, []) ->
    {ok, [{affected_rows, RowNumber}]};
get_result(return, 0, _RowNumber, _RowFormat, Rows) ->
    {ok, [{proc_result, 0, Rows}]};
get_result(block, 0, _RowNumber, _RowFormat, Rows) ->
    {ok, [{proc_result, 0, [Rows]}]};
get_result(_Type, 0, _RowNumber, [], Rows) ->
    {ok, [{proc_result, 0, Rows}]};
get_result(_Type, 1403, _RowNumber, RowFormat, Rows) ->
    Column = [get_result(Fmt) || Fmt <- RowFormat],
    {ok, [{result_set, Column, [], Rows}]};
get_result(_Type, RetCode, _RowNumber, Reason, []) ->
    {error, [{proc_result, RetCode, Reason}]};
get_result(_Type, _RetCode, _RowNumber, _RowFormat, _Rows) ->
    more.

get_result(undefined) -> [];
get_result(Cursors) when is_pid(Cursors) -> Cursors ! {get, self()}, receive Reply -> Reply end;
get_result(#format{column_name=Column}) -> Column.

freeval(undefined) -> true;
freeval(Pid) when is_pid(Pid) -> exit(Pid, ok).

currval({Sum, {0, _Cursor, _RowFormat}}, Result, Cursors) when is_pid(Cursors) ->
    Acc = get_result(Cursors),
    DefCol = {Sum, Result},
    case length(Acc) > 127 of
        true -> {reset, DefCol};
        _ -> Cursors ! {set, [DefCol|Acc]}, {more, DefCol}
    end;
currval(DefCol, _Result, _Cursors) -> {more, DefCol}.

nextval(Task) when is_pid(Task) ->
    Task ! {get, self()},
    Tseq = receive 127 -> 0; Reply -> Reply end,
    Task ! {set, Tseq + 1}, Tseq + 1;
nextval(Tseq) -> Tseq.

get_param(format, {out, Data}, Format) -> get_param(out, ?ENCODER:encode_helper(param, Data), Format);
get_param(format, {in, Data}, Format) -> get_param(in, Data, Format);
get_param(format, Data, Format) -> get_param(in, Data, Format);
get_param(Type, Data, Format) when is_atom(Type) ->
    {<<>>, DataType, Length, Scale, Charset, _Precision} = ?DECODER:decode_helper(param, Data, Format),
    #format{param=Type,data_type=DataType,data_length=Length,data_scale=Scale,charset=Charset}.

get_param(defcols, {Sum, Cursors}) when is_pid(Cursors) ->
    Acc = get_result(Cursors),
    {Sum, proplists:get_value(Sum, Acc, {0,0,[]})};
get_param(defcols, {_Sum, {LCursor, Cursor, _RowFormat}}) when LCursor =:= Cursor -> {LCursor, 0};
get_param(defcols, {_Sum, {LCursor, Cursor, _RowFormat}}) -> {LCursor, Cursor};
get_param(defcols, {{_Sum, {LCursor, Cursor, _RowFormat}}, RowFormat, Type}) when LCursor =:= 0; LCursor =/= Cursor ->
    {0, RowFormat, Type};
get_param(defcols, {{_Sum, {LCursor, _Cursor, RowFormat}}, _RowFormat, Type}) ->
    {LCursor, RowFormat, Type};
get_param(type, {true, false, [], Fetch}) -> {select, Fetch};
get_param(type, {false, true, [], _Fetch}) -> {change, 0};
get_param(type, {false, true, _Bind, _Fetch}) -> {return, 0};
get_param(type, {false, false, _Bind, _Fetch}) -> {block, 0};
get_param(type, {_Type, fetch}) -> fetch;
get_param(type, {Type, []}) -> Type;
get_param(data, {out, Data}) -> ?ENCODER:encode_helper(param, Data);
get_param(data, {in, Data}) -> Data;
get_param(data, Data) -> Data.

get_record(Type, [], Request, Task) ->
    ?ENCODER:encode_record(Type, #oraclient{req=Request, seq=nextval(Task)});
get_record(Type, State, Request, Task) ->
    ?ENCODER:encode_record(Type, State#oraclient{req=Request, seq=nextval(Task)}).

sock_renegotiate(Socket, _Opts, _Touts) when is_port(Socket) -> {ok, Socket};
sock_renegotiate(Socket, Opts, {Tout, _ReadTout}) ->
    SslOpts = proplists:get_value(ssl, Opts, []),
    {ok, Socket2} = ssl:close(Socket, {self(), Tout}),
    ssl:connect(Socket2, SslOpts, Tout).

sock_connect(Socket, [], _Tout) when is_port(Socket) -> {ok, Socket};
sock_connect(Socket, SslOpts, Tout) -> ssl:connect(Socket, SslOpts, Tout).

sock_close(undefined) -> ok;
sock_close(Socket) when is_port(Socket) -> gen_tcp:close(Socket);
sock_close(Socket) -> ssl:close(Socket).

sock_send(Socket, Packet) when is_port(Socket) -> gen_tcp:send(Socket, Packet);
sock_send(Socket, Packet) -> ssl:send(Socket, Packet).

sock_recv(Socket, Length, Tout) when is_port(Socket) -> gen_tcp:recv(Socket, Length, Tout);
sock_recv(Socket, Length, Tout) -> ssl:recv(Socket, Length, Tout).

sock_getopts(Socket, Opts) when is_port(Socket) -> inet:getopts(Socket, Opts);
sock_getopts(Socket, Opts) -> ssl:getopts(Socket, Opts).

sock_setopts(Socket, Opts) when is_port(Socket) -> inet:setopts(Socket, Opts);
sock_setopts(Socket, Opts) -> ssl:setopts(Socket, Opts).

send(State, _PacketType, <<>>) ->
    {ok, State};
send(#oraclient{socket=Socket,sdu=Length,version=Version} = State, PacketType, Data) ->
    {Packet, Rest} = ?ENCODER:encode_packet(PacketType, Data, Length, Version),
    case sock_send(Socket, Packet) of
        ok ->
            send(State, PacketType, Rest);
        {error, Reason} ->
            handle_error(socket, Reason, State)
    end.

deadline(infinity) -> infinity;
deadline(Tout) -> erlang:monotonic_time(millisecond) + Tout.

remaining(infinity) -> infinity;
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% Reads the next TNS packet, waiting for it until the call deadline.
recv_packet(#oraclient{socket=Socket, buf=Buf, version=Version, timeouts={_Tout, Deadline}} = State) ->
    case ?DECODER:decode_packet(Buf, Version) of
        {ok, ?TNS_CONTROL, _Flags, _Payload, Rest} ->
            recv_packet(State#oraclient{buf=Rest});
        {ok, Type, Flags, Payload, Rest} ->
            {ok, Type, Flags, Payload, State#oraclient{buf=Rest}};
        more ->
            case sock_recv(Socket, 0, remaining(Deadline)) of
                {ok, NetworkData} ->
                    recv_packet(State#oraclient{buf = <<Buf/binary, NetworkData/binary>>});
                {error, timeout} ->
                    {error, timeout, State};
                {error, Reason} ->
                    handle_error(socket, Reason, State)
            end;
        {error, Reason} ->
            handle_error(socket, Reason, State)
    end.

%% Receives the response to a request and decodes it as its packets arrive.
%% Without the end of response marker, the response ends with the message that
%% ends the call (error/status, as python-oracledb does); with it, the packets
%% are read up to the marked one even when the call ended before, so the next
%% call starts on a fresh response.
recv_resp(Acc, State) ->
    recv_resp({decoding, {<<>>, Acc}}, Acc, State).

recv_resp(Loop, Acc, State) ->
    case recv_packet(State) of
        {ok, Type, _Flags, Payload, State2} ->
            resp_packet(Type, Payload, Loop, Acc, State2);
        {error, timeout, State2} ->
            call_timeout(State2);
        Error ->
            Error
    end.

resp_packet(?TNS_DATA, <<?TNS_DATA_FLAGS_EOF:16, _Body/binary>>, _Loop, _Acc, State) ->
    handle_error(socket, session_shutdown, State);
resp_packet(?TNS_DATA, <<DataFlags:16, Body/binary>>, Loop, Acc, #oraclient{eor=Eor0} = State) ->
    Eor = Eor0 =:= true,
    End = Eor andalso end_of_response(DataFlags, Body),
    Loop2 =
    case Loop of
        {decoding, Cont} ->
            case ?DECODER:decode_response(Body, Cont, End) of
                {more, Cont2} -> {decoding, Cont2};
                {ok, Result} -> {decoded, Result};
                {error, Reason} -> {failed, Reason}
            end;
        _ ->
            Loop                        %the call has ended: skip to the end marker
    end,
    case Loop2 of
        {decoding, _Cont} -> recv_resp(Loop2, Acc, State);
        _ when Eor, not End -> recv_resp(Loop2, Acc, State);
        {decoded, Result2} -> {ok, Result2, State};
        {failed, Reason2} -> decode_failed(Reason2, State)
    end;
resp_packet(?TNS_MARKER, Payload, _Loop, Acc, State) ->
    %% the server broke off the call (an error, usually): after the reset the
    %% response starts over with the error
    case reset(marker_type(Payload), State) of
        {ok, Type, Payload2, State2} ->
            resp_packet(Type, Payload2, {decoding, {<<>>, Acc}}, Acc, State2);
        {error, timeout, State2} ->
            call_timeout(State2);
        Error ->
            Error
    end;
resp_packet(Type, _Payload, _Loop, _Acc, State) ->
    handle_error(socket, {unexpected_packet, Type}, State).

end_of_response(DataFlags, _Body) when DataFlags band ?TNS_DATA_FLAGS_END_OF_RESPONSE =/= 0 -> true;
end_of_response(_DataFlags, <<?TTI_EOR>>) -> true;
end_of_response(_DataFlags, _Body) -> false.

marker_type(<<_, _, Type, _/binary>>) -> Type;
marker_type(_Payload) -> undefined.

%% Sends a reset marker, discards what comes up to the server's reset marker
%% and any markers after it, and returns the next packet: the start of the
%% response that follows the break.
reset(MarkerType, State) ->
    case send(State, ?TNS_MARKER, <<1, 0, ?TNS_MARKER_RESET>>) of
        {ok, State2} when MarkerType =:= ?TNS_MARKER_RESET -> skip_markers(State2);
        {ok, State2} -> await_reset(State2);
        Error -> Error
    end.

await_reset(State) ->
    case recv_packet(State) of
        {ok, ?TNS_MARKER, _Flags, Payload, State2} ->
            case marker_type(Payload) of
                ?TNS_MARKER_RESET -> skip_markers(State2);
                _ -> await_reset(State2)
            end;
        {ok, _Type, _Flags, _Payload, State2} ->
            await_reset(State2);
        Error ->
            Error
    end.

skip_markers(State) ->
    case recv_packet(State) of
        {ok, ?TNS_MARKER, _Flags, _Payload, State2} -> skip_markers(State2);
        {ok, Type, _Flags, Payload, State2} -> {ok, Type, Payload, State2};
        Error -> Error
    end.

%% A response that does not decode: with the end of response marker it has
%% been read whole; otherwise the call is broken off so that the connection
%% is left at a known point. Either way the connection can still be used.
decode_failed(Reason, #oraclient{eor=true} = State) ->
    {error, local, Reason, State};
decode_failed(Reason, State) ->
    case break(?TNS_MARKER_BREAK, State) of
        {ok, State2} -> {error, local, Reason, State2};
        {error, _Type, Reason2, State2} -> handle_error(socket, {Reason, Reason2}, State2)
    end.

call_timeout(#oraclient{break=true} = State) ->
    handle_error(socket, timeout, State);
call_timeout(#oraclient{timeouts={Tout, _Deadline}} = State) ->
    Reason = "call timeout of " ++ integer_to_list(Tout) ++ " ms exceeded",
    case break(?TNS_MARKER_INTERRUPT, State) of
        {ok, State2} -> {error, timeout, Reason, State2};
        {error, _Type, Reason2, State2} -> handle_error(socket, {Reason, Reason2}, State2)
    end.

%% Breaks off the current call, as python-oracledb does: send a break marker,
%% skip what is left of the response up to the server's marker, reset, and
%% read the error response that follows. The server gets another call
%% timeout to answer; if it does not, the connection is closed.
break(MarkerType, #oraclient{timeouts={Tout, _Deadline}} = State) ->
    State2 = State#oraclient{timeouts={Tout, deadline(Tout)}, break=true},
    Result =
    case send(State2, ?TNS_MARKER, <<1, 0, MarkerType>>) of
        {ok, State3} when MarkerType =:= ?TNS_MARKER_BREAK ->
            reset(MarkerType, State3);
        {ok, State3} ->
            await_marker(State3);
        Error ->
            Error
    end,
    case Result of
        {ok, Type, Payload, State4} ->
            case resp_packet(Type, Payload, {decoding, {<<>>, []}}, [], State4) of
                {ok, _Result, State5} -> {ok, State5#oraclient{break=false}};
                Error2 -> Error2
            end;
        {error, timeout, State4} ->
            {error, socket, timeout, State4};
        Error3 ->
            Error3
    end.

await_marker(State) ->
    case recv_packet(State) of
        {ok, ?TNS_MARKER, _Flags, Payload, State2} -> reset(marker_type(Payload), State2);
        {ok, _Type, _Flags, _Payload, State2} -> await_marker(State2);
        Error -> Error
    end.
