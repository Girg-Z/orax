%% Decoder of the OSON binary JSON image, after OsonDecoder of python-oracledb
%% thin mode (base/oson.pyx).
%%
%% decode/1 returns the value as Elixir's JSON.decode does: objects are maps
%% with binary keys, arrays lists, strings binaries, null is nil. The other
%% Oracle types are converted by orax_values (number, date, interval, binary
%% float) and orax_vector (VECTOR).
%%
%% The buffer is the whole image and every function works on absolute
%% positions: it returns {Value, NextPos} where python moves _pos. Anything
%% unexpected is error({oson, Reason}).
-module(orax_oson).

-export([decode/1]).

-define(MAGIC, 16#ff, $J, $Z).
-define(VERSION_MAX_FNAME_255, 1).
-define(VERSION_MAX_FNAME_65535, 3).
-define(FLAG_REL_OFFSET_MODE, 16#0001).
-define(FLAG_NUM_FNAMES_UINT32, 16#0008).
-define(FLAG_IS_SCALAR, 16#0010).
-define(FLAG_NUM_FNAMES_UINT16, 16#0400).
-define(FLAG_FNAMES_SEG_UINT32, 16#0800).
-define(FLAG_TREE_SEG_UINT32, 16#1000).
-define(FLAG_SEC_FNAMES_SEG_UINT16, 16#0100).

-define(TYPE_NULL, 16#30).
-define(TYPE_TRUE, 16#31).
-define(TYPE_FALSE, 16#32).
-define(TYPE_STRING_LENGTH_UINT8, 16#33).
-define(TYPE_NUMBER_LENGTH_UINT8, 16#34).
-define(TYPE_BINARY_DOUBLE, 16#36).
-define(TYPE_STRING_LENGTH_UINT16, 16#37).
-define(TYPE_STRING_LENGTH_UINT32, 16#38).
-define(TYPE_TIMESTAMP, 16#39).
-define(TYPE_BINARY_LENGTH_UINT16, 16#3a).
-define(TYPE_BINARY_LENGTH_UINT32, 16#3b).
-define(TYPE_DATE, 16#3c).
-define(TYPE_INTERVAL_YM, 16#3d).
-define(TYPE_INTERVAL_DS, 16#3e).
-define(TYPE_TIMESTAMP_TZ, 16#7c).
-define(TYPE_TIMESTAMP7, 16#7d).
-define(TYPE_ID, 16#7e).
-define(TYPE_BINARY_FLOAT, 16#7f).
-define(TYPE_EXTENDED, 16#7b).
-define(TYPE_VECTOR, 16#01).

%% The image being decoded: data, position of the tree segment, field names
%% (a tuple), size of the field ids and relative offsets mode.
-record(oson, {data, tree_seg_pos = 0, field_names = {}, field_id_length = 1,
               relative_offsets = false}).

%% Returns the term corresponding to the OSON bytes.
decode(Data) when is_binary(Data) ->
    Rest = case Data of
               <<?MAGIC, _, Tail/binary>> -> Tail;
               _ -> error({oson, {unexpected_data, binary:part(Data, 0, min(3, byte_size(Data)))}})
           end,
    <<_:3/binary, Version, _/binary>> = Data,
    case Version of
        ?VERSION_MAX_FNAME_255 -> ok;
        ?VERSION_MAX_FNAME_65535 -> ok;
        _ -> error({oson, {version_not_supported, Version}})
    end,
    <<PrimaryFlags:16, _/binary>> = Rest,
    State = #oson{data = Data,
                  relative_offsets = PrimaryFlags band ?FLAG_REL_OFFSET_MODE =/= 0},
    Pos = 6,
    case PrimaryFlags band ?FLAG_IS_SCALAR =/= 0 of
        true ->
            %% a scalar value has a much smaller header
            Skip = case PrimaryFlags band ?FLAG_TREE_SEG_UINT32 of
                       0 -> 2;
                       _ -> 4
                   end,
            {Value, _} = decode_node(State, skip_raw_bytes(State, Pos, Skip)),
            Value;
        false ->
            decode_tree(State, Version, PrimaryFlags, Pos)
    end;
decode(Data) ->
    error({oson, {unexpected_data, Data}}).

%% The header of a document that is not a scalar, then its root node.
decode_tree(State0, Version, PrimaryFlags, Pos0) ->
    %% number of field names
    {NumShort, FieldIdLength, Pos1} =
        if
            PrimaryFlags band ?FLAG_NUM_FNAMES_UINT32 =/= 0 ->
                {N4, P4} = read_uint32be(State0, Pos0), {N4, 4, P4};
            PrimaryFlags band ?FLAG_NUM_FNAMES_UINT16 =/= 0 ->
                {N2, P2} = read_uint16be(State0, Pos0), {N2, 2, P2};
            true ->
                {N1, P1} = read_ub1(State0, Pos0), {N1, 1, P1}
        end,
    %% size of the field names segment
    {ShortOffsetsSize, ShortSegSize, Pos2} =
        case PrimaryFlags band ?FLAG_FNAMES_SEG_UINT32 =/= 0 of
            true -> {S4, Q4} = read_uint32be(State0, Pos1), {4, S4, Q4};
            false -> {S2, Q2} = read_uint16be(State0, Pos1), {2, S2, Q2}
        end,
    %% the field names longer than 255 bytes
    {LongOffsetsSize, NumLong, LongSegSize, Pos3} =
        case Version of
            ?VERSION_MAX_FNAME_65535 ->
                {SecondaryFlags, PA} = read_uint16be(State0, Pos2),
                LSize = case SecondaryFlags band ?FLAG_SEC_FNAMES_SEG_UINT16 of
                            0 -> 4;
                            _ -> 2
                        end,
                {NL, PB} = read_uint32be(State0, PA),
                {LS, PC} = read_uint32be(State0, PB),
                {LSize, NL, LS, PC};
            _ ->
                {0, 0, 0, Pos2}
        end,
    %% size of the tree segment
    {_TreeSegSize, Pos4} =
        case PrimaryFlags band ?FLAG_TREE_SEG_UINT32 =/= 0 of
            true -> read_uint32be(State0, Pos3);
            false -> read_uint16be(State0, Pos3)
        end,
    %% number of "tiny" nodes
    {_NumTinyNodes, Pos5} = read_uint16be(State0, Pos4),
    {ShortNames, Pos6} =
        case NumShort > 0 of
            true -> get_short_field_names(State0, Pos5, NumShort, ShortOffsetsSize, ShortSegSize);
            false -> {[], Pos5}
        end,
    {LongNames, Pos7} =
        case NumLong > 0 of
            true -> get_long_field_names(State0, Pos6, NumLong, LongOffsetsSize, LongSegSize);
            false -> {[], Pos6}
        end,
    State = State0#oson{field_names = list_to_tuple(ShortNames ++ LongNames),
                        field_id_length = FieldIdLength,
                        tree_seg_pos = Pos7},
    {Value, _} = decode_node(State, Pos7),
    Value.

%% Parses a container node (object or array) and returns it.
decode_container_node(State, NodeType, Pos0) ->
    #oson{tree_seg_pos = TreeSegPos, relative_offsets = Relative,
          field_id_length = FieldIdLength} = State,
    IsObject = NodeType band 16#40 =:= 0,
    %% Pos0 is after the node type byte
    ContainerOffset = Pos0 - TreeSegPos - 1,
    {NumChildren0, IsShared, Pos1} = get_num_children(State, NodeType, Pos0),
    {NumChildren, FieldIdsPos, OffsetsPos} =
        if
            IsShared ->
                {Offset, OffsetsPos0} = get_offset(State, NodeType, Pos1),
                {SharedType, P} = read_ub1(State, TreeSegPos + Offset),
                {N, _, FieldIdsPos0} = get_num_children(State, SharedType, P),
                {N, FieldIdsPos0, OffsetsPos0};
            IsObject ->
                {NumChildren0, Pos1, Pos1 + FieldIdLength * NumChildren0};
            true ->
                {NumChildren0, 0, Pos1}
        end,
    Children = decode_children(State, NodeType, IsObject, ContainerOffset, Relative,
                               NumChildren, FieldIdsPos, OffsetsPos, []),
    case IsObject of
        true -> maps:from_list(Children);
        false -> Children
    end.

%% Processes each of the children: the list of {Name, Value} for an object, of
%% values for an array.
decode_children(_State, _NodeType, _IsObject, _ContainerOffset, _Relative, 0, _FieldIdsPos, _OffsetsPos, Acc) ->
    lists:reverse(Acc);
decode_children(State, NodeType, IsObject, ContainerOffset, Relative, N, FieldIdsPos0, OffsetsPos0, Acc) ->
    #oson{field_names = FieldNames, field_id_length = FieldIdLength, tree_seg_pos = TreeSegPos} = State,
    {Name, FieldIdsPos} =
        case IsObject of
            true ->
                {Id, P} = read_uint(State, FieldIdsPos0, FieldIdLength),
                {field_name(FieldNames, Id), P};
            false ->
                {undefined, FieldIdsPos0}
        end,
    {Offset0, OffsetsPos} = get_offset(State, NodeType, OffsetsPos0),
    Offset = case Relative of
                 true -> Offset0 + ContainerOffset;
                 false -> Offset0
             end,
    {Value, _} = decode_node(State, TreeSegPos + Offset),
    Child = case IsObject of
                true -> {Name, Value};
                false -> Value
            end,
    decode_children(State, NodeType, IsObject, ContainerOffset, Relative, N - 1,
                    FieldIdsPos, OffsetsPos, [Child | Acc]).

field_name(FieldNames, Id) when Id >= 1, Id =< tuple_size(FieldNames) ->
    element(Id, FieldNames);
field_name(_FieldNames, Id) ->
    error({oson, {invalid_field_id, Id}}).

%% Parses a node from the tree segment: {Value, NextPos}.
decode_node(State, Pos0) ->
    {NodeType, Pos} = read_ub1(State, Pos0),
    decode_node(State, NodeType, Pos).

%% if the most significant bit is set the node refers to a container
decode_node(State, NodeType, Pos) when NodeType band 16#80 =/= 0 ->
    {decode_container_node(State, NodeType, Pos), Pos};
%% simple scalars
decode_node(_State, ?TYPE_NULL, Pos) -> {nil, Pos};
decode_node(_State, ?TYPE_TRUE, Pos) -> {true, Pos};
decode_node(_State, ?TYPE_FALSE, Pos) -> {false, Pos};
%% fixed length scalars
decode_node(State, NodeType, Pos) when NodeType =:= ?TYPE_DATE; NodeType =:= ?TYPE_TIMESTAMP7 ->
    fixed(State, Pos, 7, fun orax_values:date/1);
decode_node(State, ?TYPE_TIMESTAMP, Pos) ->
    fixed(State, Pos, 11, fun orax_values:date/1);
decode_node(State, ?TYPE_TIMESTAMP_TZ, Pos) ->
    fixed(State, Pos, 13, fun orax_values:date/1);
decode_node(State, ?TYPE_BINARY_FLOAT, Pos) ->
    fixed(State, Pos, 4, fun orax_values:binary_float/1);
decode_node(State, ?TYPE_BINARY_DOUBLE, Pos) ->
    fixed(State, Pos, 8, fun orax_values:binary_float/1);
decode_node(State, ?TYPE_INTERVAL_DS, Pos) ->
    fixed(State, Pos, 11, fun orax_values:interval/1);
decode_node(State, ?TYPE_INTERVAL_YM, Pos) ->
    %% python raises DB_TYPE_INTERVAL_YM not supported here
    fixed(State, Pos, 5, fun orax_values:interval/1);
%% scalars with lengths stored outside the node itself
decode_node(State, ?TYPE_STRING_LENGTH_UINT8, Pos) ->
    with_length(State, Pos, fun read_ub1/2, fun(Bin) -> Bin end);
decode_node(State, ?TYPE_STRING_LENGTH_UINT16, Pos) ->
    with_length(State, Pos, fun read_uint16be/2, fun(Bin) -> Bin end);
decode_node(State, ?TYPE_STRING_LENGTH_UINT32, Pos) ->
    with_length(State, Pos, fun read_uint32be/2, fun(Bin) -> Bin end);
decode_node(State, ?TYPE_NUMBER_LENGTH_UINT8, Pos) ->
    with_length(State, Pos, fun read_ub1/2, fun orax_values:number/1);
decode_node(State, ?TYPE_ID, Pos) ->
    with_length(State, Pos, fun read_ub1/2, fun(Bin) -> Bin end);
decode_node(State, ?TYPE_BINARY_LENGTH_UINT16, Pos) ->
    with_length(State, Pos, fun read_uint16be/2, fun(Bin) -> Bin end);
decode_node(State, ?TYPE_BINARY_LENGTH_UINT32, Pos) ->
    with_length(State, Pos, fun read_uint32be/2, fun(Bin) -> Bin end);
%% extended types
decode_node(State, ?TYPE_EXTENDED, Pos0) ->
    case read_ub1(State, Pos0) of
        {?TYPE_VECTOR, Pos} ->
            with_length(State, Pos, fun read_uint32be/2, fun orax_vector:decode/1);
        {Other, _} ->
            %% python falls through to the checks below with the extended type
            decode_small_node(State, Other, Pos0 + 1)
    end;
decode_node(State, NodeType, Pos) ->
    decode_small_node(State, NodeType, Pos).

%% number/decimal with the length stored inside the node itself, integer with
%% the length inside the node itself, string with the length inside the node
decode_small_node(State, NodeType, Pos) ->
    case NodeType band 16#f0 of
        High when High =:= 16#20; High =:= 16#60 ->
            fixed(State, Pos, (NodeType band 16#0f) + 1, fun orax_values:number/1);
        High when High =:= 16#40; High =:= 16#50 ->
            fixed(State, Pos, NodeType band 16#0f, fun orax_values:number/1);
        _ when NodeType band 16#e0 =:= 0 ->
            fixed(State, Pos, NodeType, fun(Bin) -> Bin end);
        _ ->
            error({oson, {node_type_not_supported, NodeType}})
    end.

fixed(#oson{data = Data}, Pos, Length, Fun) ->
    {Fun(get_raw(Data, Pos, Length)), Pos + Length}.

with_length(State = #oson{data = Data}, Pos0, ReadLength, Fun) ->
    {Length, Pos} = ReadLength(State, Pos0),
    {Fun(get_raw(Data, Pos, Length)), Pos + Length}.

%% Reads the short field names from the buffer: the hash id array (1 byte for
%% each field), the field name offsets array, then the names segment, each name
%% with a 1 byte length.
get_short_field_names(State = #oson{data = Data}, Pos0, NumFields, OffsetsSize, SegSize) ->
    OffsetsPos = skip_raw_bytes(State, Pos0, NumFields),
    SegPos = skip_raw_bytes(State, OffsetsPos, NumFields * OffsetsSize),
    Seg = get_raw(Data, SegPos, SegSize),
    Names = [begin
                 {Offset, _} = read_uint(State, OffsetsPos + I * OffsetsSize, OffsetsSize),
                 check_min_length(SegSize, Offset + 1),
                 <<_:Offset/binary, Len, _/binary>> = Seg,
                 check_min_length(SegSize, Offset + Len + 1),
                 binary:part(Seg, Offset + 1, Len)
             end || I <- lists:seq(0, NumFields - 1)],
    {Names, SegPos + SegSize}.

%% Reads the long field names from the buffer: same layout with a 2 bytes hash
%% id and a 2 bytes length.
get_long_field_names(State = #oson{data = Data}, Pos0, NumFields, OffsetsSize, SegSize) ->
    OffsetsPos = skip_raw_bytes(State, Pos0, NumFields * 2),
    SegPos = skip_raw_bytes(State, OffsetsPos, NumFields * OffsetsSize),
    Seg = get_raw(Data, SegPos, SegSize),
    Names = [begin
                 {Offset, _} = read_uint(State, OffsetsPos + I * OffsetsSize, OffsetsSize),
                 check_min_length(SegSize, Offset + 1),
                 <<_:Offset/binary, Len:16, _/binary>> = Seg,
                 check_min_length(SegSize, Offset + Len + 2),
                 binary:part(Seg, Offset + 2, Len)
             end || I <- lists:seq(0, NumFields - 1)],
    {Names, SegPos + SegSize}.

%% Number of children of the container, from the 4th and 5th significant bits
%% of the node type: 00 uint8, 01 uint16, 10 uint32, 11 the field ids are
%% shared with another object whose offset follows (the caller reads the
%% number of children there). Returns {NumChildren, IsShared, Pos}.
get_num_children(State, NodeType, Pos) ->
    case NodeType band 16#18 of
        16#00 -> {N, P} = read_ub1(State, Pos), {N, false, P};
        16#08 -> {N, P} = read_uint16be(State, Pos), {N, false, P};
        16#10 -> {N, P} = read_uint32be(State, Pos), {N, false, P};
        16#18 -> {0, true, Pos}
    end.

%% An offset, 16 or 32 bits depending on the 3rd significant bit of the type.
get_offset(State, NodeType, Pos) ->
    case NodeType band 16#20 of
        0 -> read_uint16be(State, Pos);
        _ -> read_uint32be(State, Pos)
    end.

%% Buffer helpers (base/buffer.pyx), on absolute positions.
get_raw(Data, Pos, Length) ->
    check_min_length(byte_size(Data) - Pos, Length),
    binary:part(Data, Pos, Length).

skip_raw_bytes(#oson{data = Data}, Pos, Length) ->
    get_raw(Data, Pos, Length),
    Pos + Length.

check_min_length(Actual, Required) when Actual >= Required -> ok;
check_min_length(Actual, Required) ->
    error({oson, {insufficient_data, Actual, Required}}).

read_ub1(#oson{data = Data}, Pos) ->
    <<V>> = get_raw(Data, Pos, 1),
    {V, Pos + 1}.

read_uint16be(#oson{data = Data}, Pos) ->
    <<V:16>> = get_raw(Data, Pos, 2),
    {V, Pos + 2}.

read_uint32be(#oson{data = Data}, Pos) ->
    <<V:32>> = get_raw(Data, Pos, 4),
    {V, Pos + 4}.

read_uint(State, Pos, 1) -> read_ub1(State, Pos);
read_uint(State, Pos, 2) -> read_uint16be(State, Pos);
read_uint(State, Pos, 4) -> read_uint32be(State, Pos).
