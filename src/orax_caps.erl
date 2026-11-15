%% The TTC capabilities negotiated with the server, after the Capabilities of
%% python-oracledb thin mode (thin/capabilities.pyx): the client sends its
%% compile time and runtime capabilities and the data types it handles in the
%% data types message, after reading those of the server in the protocol
%% response. The server picks the layout of its messages from all of them.
-module(orax_caps).

-export([new/1, adjust_for_server_caps/3]).
-export([compile_caps/2, runtime_caps/1, data_types/0]).

-include("orax.hrl").
-include("orax_data_types.hrl").

%% The (undocumented) ttc_field_version option lowers the highest field
%% version the client asks for, to test the messages of older versions
%% against a newer server.
new(Env) ->
    Max = min(?TNS_CCAP_FIELD_VERSION_MAX,
              proplists:get_value(ttc_field_version, Env, ?TNS_CCAP_FIELD_VERSION_MAX)),
    #caps{field_version = Max}.

%% The field version is the lower of the client's and the server's.
adjust_for_server_caps(#caps{field_version = Client} = Caps, CompileCaps, RuntimeCaps) ->
    ServerVersion =
    case CompileCaps of
        <<_:?TNS_CCAP_FIELD_VERSION/binary, Server, _/binary>> -> Server;
        _ -> ?TNS_CCAP_FIELD_VERSION_11_2
    end,
    FieldVersion = min(Client, ServerVersion),
    MaxStringSize =
    case RuntimeCaps of
        <<_:?TNS_RCAP_TTC/binary, Ttc, _/binary>> when Ttc band ?TNS_RCAP_TTC_32K =/= 0 -> 32767;
        _ -> 4000
    end,
    Caps#caps{field_version = FieldVersion, server_field_version = ServerVersion,
              server_compile_caps = CompileCaps,
              server_runtime_caps = RuntimeCaps, max_string_size = MaxStringSize}.

%% The compile time capabilities of the client: those of python-oracledb
%% (_init_compile_caps) with the end of response marker (TTC4) only when the
%% server offered it in the accept packet. Not asked for yet, since orax does
%% not handle what they bring: in-band notifications and explicit request
%% boundaries (TTC4), pipelining and sessionless transactions (TTC5), DRCP
%% (OCI2), HA readiness (TTC6), end user security context and transaction
%% priority (feature backport 2).
compile_caps(#caps{field_version = FieldVersion}, Eor) ->
    set_caps(<<>>, [
        {?TNS_CCAP_SQL_VERSION, ?TNS_CCAP_SQL_VERSION_MAX},
        {?TNS_CCAP_LOGON_TYPES, ?TNS_CCAP_O5LOGON bor ?TNS_CCAP_O5LOGON_NP bor
            ?TNS_CCAP_O7LOGON bor ?TNS_CCAP_O8LOGON_LONG_IDENTIFIER bor
            ?TNS_CCAP_O9LOGON_LONG_PASSWORD},
        {?TNS_CCAP_FEATURE_BACKPORT, ?TNS_CCAP_CTB_IMPLICIT_POOL bor ?TNS_CCAP_CTB_OAUTH_MSG_ON_ERR},
        {?TNS_CCAP_FIELD_VERSION, FieldVersion},
        {?TNS_CCAP_SERVER_DEFINE_CONV, 1},
        {?TNS_CCAP_DEQUEUE_WITH_SELECTOR, 1},
        {?TNS_CCAP_TTC1, ?TNS_CCAP_FAST_BVEC bor ?TNS_CCAP_END_OF_CALL_STATUS bor ?TNS_CCAP_IND_RCD},
        {?TNS_CCAP_OCI1, ?TNS_CCAP_FAST_SESSION_PROPAGATE bor ?TNS_CCAP_APP_CTX_PIGGYBACK},
        {?TNS_CCAP_TDS_VERSION, ?TNS_CCAP_TDS_VERSION_MAX},
        {?TNS_CCAP_RPC_VERSION, ?TNS_CCAP_RPC_VERSION_MAX},
        {?TNS_CCAP_RPC_SIG, ?TNS_CCAP_RPC_SIG_VALUE},
        {?TNS_CCAP_DBF_VERSION, ?TNS_CCAP_DBF_VERSION_MAX},
        {?TNS_CCAP_LOB, ?TNS_CCAP_LOB_UB8_SIZE bor ?TNS_CCAP_LOB_ENCS bor
            ?TNS_CCAP_LOB_PREFETCH_LENGTH bor ?TNS_CCAP_LOB_TEMP_SIZE bor
            ?TNS_CCAP_LOB_12C bor ?TNS_CCAP_LOB_PREFETCH_DATA},
        {?TNS_CCAP_UB2_DTY, 1},
        {?TNS_CCAP_LOB2, ?TNS_CCAP_LOB2_QUASI bor ?TNS_CCAP_LOB2_2GB_PREFETCH},
        {?TNS_CCAP_TTC3, ?TNS_CCAP_IMPLICIT_RESULTS bor ?TNS_CCAP_BIG_CHUNK_CLR bor
            ?TNS_CCAP_KEEP_OUT_ORDER bor ?TNS_CCAP_LTXID},
        {?TNS_CCAP_TTC2, ?TNS_CCAP_ZLNP},
        {?TNS_CCAP_CLIENT_FN, ?TNS_CCAP_CLIENT_FN_MAX},
        {?TNS_CCAP_SESS_SIGNATURE_VERSION, ?TNS_CCAP_FIELD_VERSION_12_2},
        {?TNS_CCAP_TTC4, case Eor of offered -> ?TNS_CCAP_END_OF_RESPONSE; _ -> 0 end},
        {?TNS_CCAP_TTC5, ?TNS_CCAP_VECTOR_SUPPORT bor ?TNS_CCAP_TOKEN_SUPPORTED},
        {?TNS_CCAP_VECTOR_FEATURES, ?TNS_CCAP_VECTOR_FEATURE_BINARY bor ?TNS_CCAP_VECTOR_FEATURE_SPARSE},
        {?TNS_CCAP_OCI3, ?TNS_CCAP_OCI3_OCSSYNC},
        {?TNS_CCAP_MAX - 1, 0}
    ]).

%% The runtime capabilities of python-oracledb (_init_runtime_caps).
runtime_caps(#caps{}) ->
    set_caps(<<>>, [
        {?TNS_RCAP_COMPAT, ?TNS_RCAP_COMPAT_81},
        {?TNS_RCAP_TTC, ?TNS_RCAP_TTC_ZERO_COPY bor ?TNS_RCAP_TTC_32K},
        {?TNS_RCAP_MAX - 1, 0}
    ]).

%% The data types table: type, conversion type and representation as ub2
%% (TNS_CCAP_UB2_DTY), ending with a zero type.
data_types() ->
    Table = << <<Type:16, Conv:16, Rep:16, 0:16>> || {Type, Conv, Rep} <- ?TNS_DATA_TYPES >>,
    <<Table/binary, 0:16>>.

%% Sets the given capability bytes, growing the array with zeros as needed.
set_caps(Caps, []) ->
    Caps;
set_caps(Caps, [{Index, Value}|Rest]) when Index >= byte_size(Caps) ->
    set_caps(<<Caps/binary, 0:((Index - byte_size(Caps) + 1) * 8)>>, [{Index, Value}|Rest]);
set_caps(Caps, [{Index, Value}|Rest]) ->
    <<Head:Index/binary, _, Tail/binary>> = Caps,
    set_caps(<<Head/binary, Value, Tail/binary>>, Rest).
