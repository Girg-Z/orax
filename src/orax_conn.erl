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
    Charset     = proplists:get_value(Cset, ?CHARSET, ?AL32UTF8_CHARSET),
    SockOpts = [binary, {active, false}, {packet, raw},
            {nodelay, true}, {keepalive, true}]++SocketOpts,
    Desc        = proplists:get_value(description, Opts, []),
    Pass        = proplists:get_value(password, Opts),
    NewPass     = proplists:get_value(newpassword, Opts, []),
    EnvOpts     = proplists:delete(password, proplists:delete(newpassword, Opts)),
    %% kept in a closure, so that the password does not show in the state
    Passwd = fun() -> {Pass, NewPass} end,
    case gen_tcp:connect(Host, Port, SockOpts, Tout) of
        {ok, Socket} ->
            case sock_connect(Socket, SslOpts, Tout) of
                {ok, Socket2} ->
                    {ok, [{recbuf, RecBuf}]} = sock_getopts(Socket2, [recbuf]),
                    sock_setopts(Socket2, [{buffer, RecBuf}]),
                    State = #oraclient{socket=Socket2, env=EnvOpts, passwd=Passwd, auth=Desc,
                    auto=Auto, fetch=Fetch, sdu=Sdu, charset=Charset, timeouts={Tout, deadline(Tout)},
                    caps=orax_caps:new(EnvOpts)},
                    case send_req(login, State) of
                        {ok, State2} ->
                            handle_login(connect, State2#oraclient{conn_state=auth_negotiate});
                        Error ->
                            Error
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    handle_error(socket, Reason, #oraclient{})
            end;
        {error, Reason} ->
            handle_error(socket, Reason, #oraclient{})
    end.

-spec disconnect(state()) -> {ok, [env()]}.
disconnect(#oraclient{socket=Socket, env=Env}) ->
    sock_close(Socket),
    {ok, Env}.

-spec disconnect(state(), timeout()) -> {ok, []}.
disconnect(#oraclient{socket=Socket} = State, _Tout) ->
    send_req(close, State),
    sock_close(Socket),
    {ok, []}.

-spec reconnect(state()) -> empty_result().
reconnect(#oraclient{passwd=Passwd} = State) ->
    {Pass, NewPass} = Passwd(),
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
%% The next rows of a cursor fetched with {fetch, Query, Bind}: they come
%% after the last row of the previous fetch.
query(#oraclient{conn_state=connected} = State, {fetch, Cursor, Columns, LastRow}) ->
    fetch(State, Cursor, Columns, [LastRow], LastRow, fetch);
query(#oraclient{conn_state=connected} = State, {Query, Bind, Batch, Fetch}) ->
    execute(State, Query, Bind, Batch, Fetch);
query(#oraclient{conn_state=connected, timeouts={_Tout, Deadline}} = State, {Query, Bind}) ->
    case lists:nth(1, string:tokens(string:to_upper(Query)," \t;")) of
        "SESSION" -> query(State, {?ENCODER:encode_helper(sess, []), [], [], []});
        "COMMIT" -> call(tran, State, ?TTI_COMMIT);
        "ROLLBACK" -> call(tran, State, ?TTI_ROLLBACK);
        %% Autocommit is the commit-on-success option sent with each execute;
        %% the legacy TTI_COMON/TTI_COMOFF calls fail on recent servers
        %% (ORA-03154), so only the client-side flag is switched.
        "COMON" -> {ok, [], State#oraclient{auto=1}};
        "COMOFF" -> {ok, [], State#oraclient{auto=0}};
        "PING" -> call(tran, State, ?TTI_PING);
        "STOP" -> call(stop, State, hd(Bind));
        "START" ->
            State2 = state_of(call(spfp, State, []), State),
            call(start, State2, hd(Bind));
        "CLOSE" -> send_req(close, State), handle_error(local, [], State);
        "CURRESET" ->
            #oraclient{cursors=Cursors, close=Close} = State,
            State2 = State#oraclient{cursors=#{}, close=Close ++ [Id || {Id, _} <- maps:values(Cursors)]},
            {ok, [], state_of(call(tran, State2, ?TTI_PING), State2)};
        "TIMEOUT" -> {ok, [], State#oraclient{timeouts={hd(Bind), Deadline}}};
        "FETCH" -> {ok, [], State#oraclient{fetch=hd(Bind)}};
        _ -> {ok, undefined, State}
    end.

%% internal

%% Login: connect, protocol and data types negotiation, then the two phases
%% of the authentication. Each step reads the response to the previous one.
handle_login(Step, State) ->
    case recv_packet(State) of
        {ok, ?TNS_DATA, _Flags, Payload, State2} ->
            case resp_packet(?TNS_DATA, Payload, {decoding, {<<>>, new_resp(Step, State2)}}, new_resp(Step, State2), State2) of
                {ok, Resp, State3} -> login_step(Step, Resp, State3);
                Error -> Error
            end;
        {ok, ?TNS_RESEND, _Flags, _Payload, #oraclient{socket=Socket, env=Env, timeouts=Touts} = State2} ->
            {ok, Socket2} = sock_renegotiate(Socket, Env, Touts),
            {ok, State3} = send_req(login, State2#oraclient{socket=Socket2, buf = <<>>}),
            handle_login(Step, State3);
        {ok, ?TNS_ACCEPT, _Flags, Payload, #oraclient{env=Env} = State2} ->
            {Version, Sdu, Flags2} = accept_params(Payload),
            %% the server marks the end of responses once the data types
            %% message has asked for it in the compile time capabilities
            Eor = Version >= ?TNS_VERSION_MIN_END_OF_RESPONSE
                andalso Flags2 band ?TNS_ACCEPT_FLAG_HAS_END_OF_RESPONSE =/= 0
                andalso proplists:get_value(end_of_response, Env, true)
                andalso offered,
            Seq = atomics:new(1, []),
            case send_req(pro, State2#oraclient{seq=Seq, sdu=Sdu, version=Version, eor=Eor}) of
                {ok, State3} -> handle_login(protocol, State3);
                Error -> Error
            end;
        {ok, ?TNS_MARKER, _Flags, Payload, State2} ->
            case resp_packet(?TNS_MARKER, Payload, {decoding, {<<>>, new_resp(call, State2)}}, new_resp(call, State2), State2) of
                {ok, Resp, State3} -> login_error(Resp, State3);
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
            handle_error(local, Rest, State2);
        {ok, Type, _Flags, _Payload, State2} ->
            handle_error(socket, {unexpected_packet, Type}, State2);
        {error, timeout, State2} ->
            handle_error(socket, timeout, State2);
        Error ->
            Error
    end.

%% The response to each login step and the request that follows it.
login_step(_Step, #resp{error_num=Num} = Resp, State) when Num =/= 0 ->
    login_error(Resp, State);
login_step(protocol, #resp{server_caps={CompileCaps, RuntimeCaps}}, #oraclient{caps=Caps} = State) ->
    Caps2 = orax_caps:adjust_for_server_caps(Caps, CompileCaps, RuntimeCaps),
    {ok, State2} = send_req(dty, State#oraclient{caps=Caps2}),
    handle_login(data_types, State2);
login_step(data_types, _Resp, #oraclient{eor=Eor, caps=Caps} = State) ->
    State2 = State#oraclient{eor=Eor =:= offered, caps=Caps#caps{end_of_response=Eor =:= offered}},
    {ok, State3} = send_req(sess, State2),
    handle_login(sess, State3);
login_step(sess, #resp{session_data=Values}, State) ->
    Logon = #logon{type=session_value("AUTH_VFR_DATA", Values, 3),
                   auth=session_value("AUTH_SESSKEY", Values),
                   salt=session_value("AUTH_VFR_DATA", Values),
                   der_salt=session_value("AUTH_PBKDF2_CSK_SALT", Values)},
    {ok, State2} = send_req(auth, State#oraclient{req=Logon}),
    handle_login(auth, State2);
login_step(auth, #resp{session_data=Values}, #oraclient{auth=KeyConn} = State) ->
    Resp = session_value("AUTH_SVR_RESPONSE", Values),
    Ver = case session_value("AUTH_VERSION_NO", Values) of
        undefined -> 0;
        Value -> list_to_integer(Value) bsr 24
    end,
    SessId = session_value("AUTH_SESSION_ID", Values),
    case orax_crypt:validate(#logon{auth=Resp, key=KeyConn}) of
        ok -> {ok, State#oraclient{conn_state=connected,auth=SessId,server=Ver}};
        error -> handle_error(remote, Resp, State)
    end.

login_error(#resp{error_num=Num, error_message=Message}, State) ->
    {ok, [{proc_result, Num, Message}], State}.

session_value(Key, Values) -> session_value(Key, Values, 2).

session_value(Key, Values, N) ->
    case lists:keyfind(Key, 1, Values) of
        false -> undefined;
        Value -> element(N, Value)
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

handle_error(remote, Reason, State) ->
    {error, remote, Reason, State};
handle_error(socket, Reason, State) ->
    disconnect(State),
    {error, socket, Reason, State#oraclient{conn_state=disconnected}};
handle_error(local, Reason, State) ->
    disconnect(State),
    {ok, Reason, State#oraclient{conn_state=disconnected}}.

new_resp(Step, #oraclient{caps=Caps}) ->
    Msg = case Step of
        connect -> protocol;
        sess -> auth;
        _ -> Step
    end,
    #resp{caps=Caps, msg=Msg}.

%% Calls

%% A function without data (commit, rollback, ping, ...): empty result or the
%% error.
call(Type, State, Request) ->
    case send_req(Type, State#oraclient{req=Request}) of
        {ok, State2} ->
            case recv_resp(new_resp(call, State2), State2) of
                {ok, #resp{error_num=0}, State3} -> {ok, [], State3};
                {ok, #resp{error_num=Num, error_message=Message}, State3} ->
                    {ok, [{proc_result, Num, Message}], State3};
                Error -> Error
            end;
        Error -> Error
    end.

%% Executes a statement (python-oracledb's ExecuteMessage). Queries open a
%% cursor whose columns are defined after the describe (CLOB/BLOB as
%% LONG/LONG RAW) before the rows are fetched; the cursor and its columns are
%% kept for the next executions of the statement with binds of the same types.
execute(State, Query, Bind, Batch, Mode) ->
    {Kind, Binds} = statement(Query, Bind),
    Rows = [[bind_value(B) || B <- Row] || Row <- [Binds|Batch]],
    Formats = [?ENCODER:bind_format(B, Values) || {B, Values} <- lists:zip(Binds, columns_of(Rows))],
    case supported(Formats, State) of
        ok -> execute(State, Query, Kind, Binds, Rows, Formats, Mode);
        {error, Reason} -> {error, local, Reason, State}
    end.

%% VECTOR values travel as such from the TTC field version of 23.4 on.
supported(Formats, #oraclient{caps=#caps{field_version=Version}}) ->
    case [F || #format{data_type=?TNS_TYPE_VECTOR} = F <- Formats] of
        [_|_] when Version < ?TNS_CCAP_FIELD_VERSION_23_4 ->
            {error, <<"VECTOR binds are not supported before Oracle Database 23.4">>};
        _ -> ok
    end.

execute(#oraclient{cursors=Cursors, fetch=Fetch, auto=Auto} = State, Query, Kind, Binds, Rows, Formats, Mode) ->
    Type = result_type(Kind, Binds),
    Sql = ?ENCODER:encode_str(Query),
    Key = {erlang:crc32(Sql), [F#format.data_type || F <- Formats]},
    {CursorId, Columns} =
    case maps:find(Key, Cursors) of
        {ok, Cached} when Kind =/= ddl -> Cached;
        _ -> {0, []}
    end,
    Exec = #exec{cursor_id=CursorId, sql=Sql, kind=Kind, returning=Type =:= return,
                 binds=Formats, rows=Rows,
                 prefetch=if Kind =:= query, CursorId =/= 0 -> Fetch; true -> 0 end,
                 commit=Auto =:= 1 andalso Kind =/= query},
    Resp = (new_resp(execute, State))#resp{in_fetch=Kind =:= query, returning=Type =:= return,
        binds=Formats, columns=Columns, cursor_id=CursorId,
        out=case Type of
            return -> [F || #format{param=out} = F <- Formats];
            _ -> Columns
        end},
    Key2 = if Kind =:= ddl -> undefined; true -> Key end,
    case request(exec, State, Exec, Resp) of
        {ok, Resp2, State2} -> executed(Type, Key2, Mode, Resp2, State2);
        Error -> Error
    end.

%% What a statement returns: rows (select), the number of rows changed
%% (change), the values of its return binds (return) or of its out binds
%% (block, PL/SQL and anything else).
result_type(query, Binds) ->
    case [B || {out, _} = B <- Binds] of
        [] -> select;
        _ -> block
    end;
result_type(dml, Binds) ->
    case [B || {out, _} = B <- Binds] of
        [] -> change;
        _ -> return
    end;
result_type(_Kind, _Binds) ->
    block.

executed(_Type, Key, _Mode, #resp{error_num=Num, error_message=Message} = Resp, State)
  when Num =/= 0, Num =/= ?TNS_ERR_NO_DATA_FOUND orelse not Resp#resp.in_fetch ->
    {ok, [{proc_result, Num, Message}], uncache(Key, Num, Resp, State)};
executed(select, Key, Mode, #resp{cursor_id=CursorId, columns=Columns} = Resp, #oraclient{cursors=Cursors} = State) ->
    case maps:is_key(Key, Cursors) of
        true ->
            fetched(State, CursorId, Columns, Resp, Mode);
        false ->
            Columns2 = [fetch_format(C) || C <- Columns],
            State2 = cache(Key, {CursorId, Columns2}, State),
            define(State2, CursorId, Columns2, Mode)
    end;
executed(change, Key, _Mode, #resp{cursor_id=CursorId, rowcount=RowCount}, State) ->
    {ok, [{affected_rows, RowCount}], cache(Key, {CursorId, []}, State)};
executed(return, Key, _Mode, #resp{cursor_id=CursorId, rows=Rows}, State) ->
    Values =
    case lists:reverse(Rows) of
        [] -> [];
        [First|More] -> lists:foldl(fun(Row, Acc) -> lists:zipwith(fun erlang:'++'/2, Acc, Row) end, First, More)
    end,
    {ok, [{proc_result, 0, Values}], cache(Key, {CursorId, []}, State)};
executed(block, Key, Mode, #resp{cursor_id=CursorId, rows=Rows}, State) ->
    State2 = cache(Key, {CursorId, []}, State),
    Values = case Rows of [] -> []; [Row|_] -> Row end,
    case [V || {cursor, _, _} = V <- Values] of
        [{cursor, RefCursor, Columns}|_] ->
            %% the rows of the first REF CURSOR out bind
            Columns2 = [fetch_format(C) || C <- Columns],
            case define(State2, RefCursor, Columns2, Mode) of
                {ok, Result, State3} -> {ok, Result, State3#oraclient{close=State3#oraclient.close ++ [RefCursor]}};
                Error -> Error
            end;
        [] ->
            {ok, [{proc_result, 0, [Values]}], State2}
    end.

%% Defines the columns of an open cursor and fetches its first rows.
define(#oraclient{fetch=Fetch} = State, CursorId, Columns, Mode) ->
    Exec = #exec{cursor_id=CursorId, kind=query, defines=[define_format(C) || C <- Columns], prefetch=Fetch},
    Resp = (new_resp(execute, State))#resp{in_fetch=true, columns=Columns, out=Columns},
    case request(exec, State, Exec, Resp) of
        {ok, Resp2, State2} -> fetched(State2, CursorId, Columns, Resp2, Mode);
        Error -> Error
    end.

%% Fetches more rows; Rows are the ones fetched so far (last first).
fetch(State, CursorId, Columns, Rows, LastRow, Mode) ->
    Resp = (new_resp(execute, State))#resp{in_fetch=true, columns=Columns, out=Columns,
                                            rows=Rows, last_row=LastRow},
    case request(fetch, State, CursorId, Resp) of
        {ok, Resp2, State2} -> fetched(State2, CursorId, Columns, Resp2, Mode);
        Error -> Error
    end.

%% All the rows are fetched when the server returns "no data found".
fetched(State, _CursorId, Columns, #resp{error_num=?TNS_ERR_NO_DATA_FOUND, rows=Rows}, _Mode) ->
    {ok, [{result_set, [Name || #format{column_name=Name} <- Columns], [], lists:reverse(Rows)}], State};
fetched(State, _CursorId, _Columns, #resp{error_num=Num, error_message=Message}, _Mode) when Num =/= 0 ->
    {ok, [{proc_result, Num, Message}], State};
fetched(State, CursorId, Columns, #resp{rows=Rows}, fetch) ->
    {ok, [{fetched_rows, CursorId, Columns, lists:reverse(Rows)}], State};
fetched(State, CursorId, Columns, #resp{rows=Rows, last_row=LastRow}, Mode) ->
    fetch(State, CursorId, Columns, Rows, LastRow, Mode).

%% The type the values of a column are fetched as (_create_fetch_var with
%% fetch_lobs=False): CLOB/BLOB as LONG/LONG RAW, OSON in a BLOB as LONG RAW
%% (decoded as JSON). The buffer size stays the one of the describe.
fetch_format(#format{data_type=?TNS_TYPE_CLOB} = Format) ->
    Format#format{data_type=?TNS_TYPE_LONG};
fetch_format(#format{data_type=DataType, is_oson=true} = Format) when DataType =/= ?TNS_TYPE_JSON ->
    Format#format{data_type=?TNS_TYPE_LONGRAW};
fetch_format(#format{data_type=?TNS_TYPE_BLOB} = Format) ->
    Format#format{data_type=?TNS_TYPE_LONGRAW};
fetch_format(Format) ->
    Format.

%% The define of a column: its buffer size from the type and the maximum
%% size of the describe (OracleMetadata._finalize_init).
define_format(#format{data_type=DataType, max_size=MaxSize} = Format) ->
    BufferSize =
    case DataType of
        _ when ?IS_LONG_TYPE(DataType) -> ?TNS_MAX_LONG_LENGTH;
        _ when ?IS_CHAR_TYPE(DataType) -> max(MaxSize, 1) * 4;
        _ when ?IS_RAW_TYPE(DataType) -> if MaxSize > 0 -> MaxSize; true -> 4000 end;
        _ when ?IS_NUMBER_TYPE(DataType); DataType =:= ?TNS_TYPE_BINARY_INTEGER -> 22;
        ?TNS_TYPE_DATE -> 7;
        ?TNS_TYPE_TIMESTAMP -> 11;
        ?TNS_TYPE_TIMESTAMPLTZ -> 11;
        ?TNS_TYPE_TIMESTAMPTZ -> 13;
        ?TNS_TYPE_INTERVALDS -> 11;
        ?TNS_TYPE_INTERVALYM -> 5;
        ?TNS_TYPE_BFLOAT -> 4;
        ?TNS_TYPE_BDOUBLE -> 8;
        ?TNS_TYPE_BOOLEAN -> 4;
        _ when ?IS_ROWID_TYPE(DataType) -> 18;
        _ -> Format#format.data_length
    end,
    Format#format{data_length=BufferSize}.

%% The statement cache: up to 128 cursors; beyond that all of them are
%% closed. A statement that fails keeps its cursor only on integrity errors.
cache(undefined, _Value, State) ->
    State;
cache(_Key, {0, _Columns}, State) ->
    State;
cache(Key, Value, #oraclient{cursors=Cursors, close=Close} = State) ->
    case maps:is_key(Key, Cursors) orelse map_size(Cursors) < 128 of
        true -> State#oraclient{cursors=Cursors#{Key => Value}};
        false ->
            State#oraclient{cursors=#{Key => Value},
                            close=Close ++ [Id || {Id, _} <- maps:values(Cursors)]}
    end.

uncache(_Key, Num, _Resp, State) when Num =:= 1; Num =:= 1400; Num =:= 1438; Num =:= 2290;
                                      Num =:= 2291; Num =:= 2292; Num =:= 21525; Num =:= 40479 ->
    State;
uncache(Key, _Num, #resp{cursor_id=CursorId}, #oraclient{cursors=Cursors, close=Close} = State) ->
    Close2 = if CursorId =/= 0 -> Close ++ [CursorId]; true -> Close end,
    State#oraclient{cursors=maps:remove(Key, Cursors), close=Close2}.

%% The kind of statement from its first keyword (Statement._determine_
%% statement_type) and its binds in the order of their placeholders.
statement(Query, Bind) ->
    Ks = string:tokens(Query," \t\r\n;,()="),
    Kind =
    case string:to_upper(hd(Ks)) of
        K when K =:= "DECLARE"; K =:= "BEGIN"; K =:= "CALL" -> plsql;
        K when K =:= "SELECT"; K =:= "WITH" -> query;
        K when K =:= "INSERT"; K =:= "UPDATE"; K =:= "DELETE"; K =:= "MERGE" -> dml;
        K when K =:= "CREATE"; K =:= "ALTER"; K =:= "DROP"; K =:= "GRANT"; K =:= "REVOKE";
               K =:= "ANALYZE"; K =:= "AUDIT"; K =:= "COMMENT"; K =:= "TRUNCATE" -> ddl;
        _ -> other
    end,
    Names = lists:filtermap(fun(L) -> if hd(L) =:= $: -> {true, tl(L)}; true -> false end end, Ks),
    {Kind, binds(Names, Bind)}.

binds(Names, Bind) when is_list(Bind) ->
    try lists:map(fun(L) -> list_to_integer(L) end, Names) of
        Bs -> lists:map(fun(I) -> lists:nth(I, Bind) end, Bs)
    catch
        error:_ -> Bind
    end;
binds(Names, Bind) when is_map(Bind) ->
    lists:map(fun(L) -> maps:get(list_to_atom(L), Bind) end, Names).

bind_value({out, _Type}) -> null;
bind_value({in, Value}) -> Value;
bind_value(Value) -> Value.

columns_of([Row]) -> [[V] || V <- Row];
columns_of([Row|_] = Rows) -> [[lists:nth(I, R) || R <- Rows] || I <- lists:seq(1, length(Row))].

%% Sends a request and reads its response. The cursors to close go before it
%% in a piggyback; a flush out binds message asks for the rest of the
%% response.
request(Type, #oraclient{close=Close} = State, Request, Resp) ->
    Piggyback =
    case Close of
        [] -> <<>>;
        _ -> get_record(close_cursors, State, Close)
    end,
    Data = get_record(Type, State, Request),
    case send(State#oraclient{close=[]}, ?TNS_DATA, <<Piggyback/binary, Data/binary>>) of
        {ok, State2} -> response(Resp, State2);
        Error -> Error
    end.

response(Resp, State) ->
    case recv_resp(Resp, State) of
        {ok, #resp{flush_out_binds=true} = Resp2, State2} ->
            case send(State2, ?TNS_DATA, <<?TTI_FOB>>) of
                {ok, State3} -> response(Resp2#resp{flush_out_binds=false, end_of_response=false}, State3);
                Error -> Error
            end;
        Result ->
            Result
    end.

state_of({ok, State}, _State) -> State;
state_of({ok, _Result, State}, _State) -> State;
state_of({error, _Type, _Reason, State}, _State) -> State;
state_of(_Result, State) -> State.

%% The sequence number of each request: 1 to 127, then 1 again. A counter, as
%% some requests are sent with a state that is not passed on (closing the
%% cursors on logoff, the rollback before it).
nextval(Seq) when is_reference(Seq) ->
    Next = atomics:get(Seq, 1) rem 127 + 1,
    atomics:put(Seq, 1, Next),
    Next;
nextval(Seq) -> Seq.

send_req(login, State) ->
    {Connect, Data} = ?ENCODER:encode_record(login, State),
    case send(State, ?TNS_CONNECT, Connect) of
        {ok, State2} -> send(State2, ?TNS_DATA, Data);
        Error -> Error
    end;
send_req(auth, #oraclient{req=Request} = State) ->
    {Data, KeyConn} = get_record(auth, State, Request),
    send(State#oraclient{auth=KeyConn,req=[]}, ?TNS_DATA, Data);
%% Logoff (rolling back first when autocommit is off, closing the cursors),
%% then the end of the data.
send_req(close, #oraclient{server=0, socket=Socket, version=Version}) ->
    {Packet, _} = ?ENCODER:encode_packet(eof, <<>>, 0, Version),
    sock_send(Socket, Packet);
send_req(close, #oraclient{auto=0} = State) ->
    _ = call(tran, State, ?TTI_ROLLBACK),
    send_req(close, State#oraclient{auto=1});
send_req(close, #oraclient{cursors=Cursors, close=Close} = State) ->
    State2 = State#oraclient{cursors=#{}, close=Close ++ [Id || {Id, _} <- maps:values(Cursors)]},
    _ = request(close, State2, [], new_resp(call, State2)),
    send_req(close, State2#oraclient{server=0});
send_req(Type, #oraclient{req=Request} = State) ->
    Data = get_record(Type, State, Request),
    send(State, ?TNS_DATA, Data).

get_record(Type, #oraclient{seq=Seq} = State, Request) ->
    ?ENCODER:encode_record(Type, State#oraclient{req=Request, seq=nextval(Seq)}).

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
%% call starts on a fresh response. A flush out binds message ends the part
%% of the response sent so far either way (python-oracledb's Protocol.
%% _process_message): the rest comes after the client asks for it.
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
        %% the server waits for the flush out binds request before sending
        %% the rest of the response: no end marker comes before it
        {decoded, #resp{flush_out_binds=true} = Flushed} -> {ok, Flushed, State};
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
            Resp = new_resp(call, State4),
            case resp_packet(Type, Payload, {decoding, {<<>>, Resp}}, Resp, State4) of
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
