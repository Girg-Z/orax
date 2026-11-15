%% Decoding the bytes of Oracle values, after base/decoders.pyx of
%% python-oracledb: NUMBER, BINARY_FLOAT/DOUBLE, DATE/TIMESTAMP and INTERVAL.
%% Text (interval year to month, time zones) comes as binaries.
-module(orax_values).

-export([number/1, number/3, binary_float/1, date/1, interval/1, tz_offset/2]).

-include("orax.hrl").

%% NUMBER: integral values as integers, the others as floats.
number(<<128>>) -> 0;
number(Data) ->
    {N, [I|L]} = lnxfmt(binary_to_list(Data)),
    H = length(L),
    N *
    case (I + 1) > (H - 1) of
        true ->  lnxsni([I|L],H);
        false -> lnxnur([I|L],H)
    end.

%% NUMBER of a column with the given scale and precision: scale 0 gives
%% integers. Scale -127 with precision 0 is an unconstrained NUMBER: a NUMBER
%% column without precision, or an expression such as count(*) once Oracle
%% wraps it in a subquery (FETCH NEXT, ROWNUM). Integral values come back as
%% integers, like NUMBER(p,0); FLOAT columns report a binary precision and
%% stay floats.
number(Data, Scale, Precision) ->
    lsc(number(Data), Scale, Precision).

lnxsni([I|L],20) ->
    lnxnur(L,I,0);
lnxsni(L,I) ->
    lnxsni(L++[0],I+1).

lnxnur([H|L],I) ->
    lnxnur(L,I,0) / lnxnur(1,I-H-1);
lnxnur(N,0) when is_integer(N) ->
    N;
lnxnur(N,I) when is_integer(N) ->
    lnxnur(N * 100, I-1).

lnxnur([],0,Acc) ->
    Acc;
lnxnur([H|_L],0,Acc) ->
    Acc * 100 + H;
lnxnur([H|L],I,Acc) ->
    lnxnur(L,I-1,Acc * 100 + H).

%% Negative numbers end with 102 when they have less than 20 digits.
lnxneg([]) -> [];
lnxneg([102]) -> [];
lnxneg([H|T]) -> [H|lnxneg(T)].

lnxfmt([I|L]) when I band 128 =:= 0 ->
    {-1, [(((I bxor 255) band 127) - 65)|[ 101-N || N <- lnxneg(L)]]};
lnxfmt([I|L]) ->
    {1, [((I band 127) - 65)|[ N-1 || N <- L]]}.

lsc(I, 0, _P) when is_integer(I) -> I;
lsc(I, 0, _P) when I-trunc(I) =:= +0.0 -> trunc(I);
lsc(I, 0, _P) -> I;
lsc(I, -127, 0) when is_integer(I) -> I;
lsc(I, -127, 0) when I == trunc(I) -> trunc(I);
lsc(I, -127, 0) -> I;
lsc(I, _S, _P) -> I / 1.

%% BINARY_FLOAT (4 bytes) and BINARY_DOUBLE (8 bytes): IEEE 754 with the sign
%% bit flipped for positive values and every bit inverted for negative ones.
%% NaN and the infinities, which Erlang floats cannot hold, become atoms.
binary_float(<<I, Rest/binary>>) when I band 128 =/= 0 ->
    ieee(<<(I band 127), Rest/binary>>);
binary_float(Data) ->
    ieee(<< <<(B bxor 255)>> || <<B>> <= Data >>).

ieee(<<Sign:1, 255:8, Fraction:23>>) -> special(Sign, Fraction);
ieee(<<Sign:1, 2047:11, Fraction:52>>) -> special(Sign, Fraction);
ieee(<<Value:32/float>>) -> Value;
ieee(<<Value:64/float>>) -> Value.

special(_Sign, Fraction) when Fraction =/= 0 -> nan;
special(0, 0) -> infinity;
special(1, 0) -> '-infinity'.

%% DATE (7 bytes), TIMESTAMP (11, or 7 without fractional seconds) and
%% TIMESTAMP WITH (LOCAL) TIME ZONE (13): the offset or region of the time
%% zone is appended. A zero hour or minute byte means no time zone (UTC).
date(<<Century,Year,Mon,Day,Hour,Min,Sec>>) ->
    {{(Century - 100) * 100 + (Year - 100),(Mon),(Day)},
     {(Hour - 1),(Min - 1),(Sec - 1)}};
date(<<Data:7/binary,Ms:4/integer-unit:8>>) ->
    {D, {Hour,Min,Sec}} = date(Data),
    {D, {Hour,Min,Sec + Ms / 1.0e9}};
date(<<Data:7/binary,Ms:4/integer-unit:8,H,M>>) when H =:= 0; M =:= 0 ->
    erlang:append_element(date(<<Data/binary,Ms:32>>), zone(tz_offset(0, 0)));
date(<<Data:7/binary,Ms:4/integer-unit:8,H,M>>) when H band ?TNS_HAS_REGION_ID =:= 0 ->
    Offset = (H - ?TZ_HOUR_OFFSET) * 3600 + (M - ?TZ_MINUTE_OFFSET) * 60,
    {D, {Hour,Min,Sec}} = shift(Data, Offset),
    erlang:append_element({D, {Hour,Min,Sec + Ms / 1.0e9}},
        zone(tz_offset(H - ?TZ_HOUR_OFFSET, M - ?TZ_MINUTE_OFFSET)));
date(<<Data:7/binary,Ms:4/integer-unit:8,H,M>>) ->
    case ((H band 127) bsl 6) + ((M band 252) bsr 2) of
        I when I > 0, I < 28 ->
            S = lists:nth(I, [0,14,13,12,11,10,9,8,7,6,5,4,3,2,1,-1,-2,-3,-4,-5,-6,-7,-8,-9,-10,-11,-12]),
            {D, {Hour,Min,Sec}} = shift(Data, S * 3600),
            erlang:append_element({D, {Hour,Min,Sec + Ms / 1.0e9}}, zone(tz_offset(S, 0)));
        Zoneid ->
            erlang:append_element(date(<<Data:7/binary,Ms:4/integer-unit:8>>),
            case proplists:get_value(Zoneid, ?ZONEIDMAP) of
                undefined -> {Zoneid};
                {Region, Zone} -> zone(lists:nth(Region, ?REGION)++"/"++Zone)
            end)
    end.

zone(Name) -> list_to_binary(Name).

shift(Data, Offset) ->
    Secs = calendar:datetime_to_gregorian_seconds(date(Data)),
    calendar:gregorian_seconds_to_datetime(Secs + Offset).

%% INTERVAL YEAR TO MONTH as <<"Y-M">>, INTERVAL DAY TO SECOND as
%% {Days, {Hours, Minutes, Seconds}}, negative when any field is.
interval(<<Year:32,Mon>>) ->
    list_to_binary(lym(Year - ?TNS_DURATION_MID, Mon - ?TNS_DURATION_OFFSET));
interval(<<Day:32,Hour,Min,Sec,Ms:32>>) ->
    lds(Day - ?TNS_DURATION_MID, Hour - ?TNS_DURATION_OFFSET, Min - ?TNS_DURATION_OFFSET,
        Sec - ?TNS_DURATION_OFFSET, (Ms - ?TNS_DURATION_MID) / 1.0e9).

%% A time zone offset as "+HH:MM" (a string, also used in ALTER SESSION).
tz_offset(I, M) when I < 0; M < 0 -> tz_offset(abs(I), abs(M), "-");
tz_offset(I, M) -> tz_offset(I, M, "+").

tz_offset(I, M, S) ->
    S ++ pad(I) ++ ":" ++ pad(M).

pad(I) when I < 10 -> [$0|integer_to_list(I)];
pad(I) -> integer_to_list(I).

lym(I, M) when I < 0; M < 0 -> "-"++lym(abs(I), abs(M));
lym(I, M) -> integer_to_list(abs(I))++"-"++integer_to_list(abs(M)).

%% A negative interval carries the sign on its first field that is not zero.
lds(I, H, M, S, Ms) when I < 0; H < 0; M < 0; S < 0; Ms < 0 ->
    case {abs(I), abs(H), abs(M), abs(S) + abs(Ms)} of
        {0, 0, 0, S2} -> {0, {0, 0, -S2}};
        {0, 0, M2, S2} -> {0, {0, -M2, S2}};
        {0, H2, M2, S2} -> {0, {-H2, M2, S2}};
        {I2, H2, M2, S2} -> {-I2, {H2, M2, S2}}
    end;
lds(I, H, M, S, Ms) ->
    {abs(I), {abs(H), abs(M), abs(S) + abs(Ms)}}.
