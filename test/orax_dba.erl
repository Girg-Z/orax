-module(orax_dba).

-include("orax_test.hrl").

-compile(export_all).

%% To use this module, you must set the DEF_TIMEOUT to infinity.

startdb() ->                     % as sysdba prelim auth
    {ok, ConnRef} = orax:start([{role, 1},{prelim, 1}]++?ConnOpts),

    {ok,[_]} =                   %mode 0 norestrict, 1 restrict, 16 force
    orax:sql_query(ConnRef, {"START", [0]}),
    
    ok = orax:stop(ConnRef).

mountdb() ->                     % as sysdba
    {ok, ConnRef} = orax:start([{role, 1}]++?ConnOpts),

    {ok,[_]} =
    orax:sql_query(ConnRef, "ALTER DATABASE MOUNT"),

    {ok,[_]} =
    orax:sql_query(ConnRef, "ALTER DATABASE OPEN"),

    ok = orax:stop(ConnRef).
    
stopdb() ->                     % as sysdba
    {ok, ConnRef} = orax:start([{role, 1}]++?ConnOpts),

    {ok,[_]} =                  %mode 2 immediate, 4 normal, 8 final, 64 abort, 128 tran
    orax:sql_query(ConnRef, {"STOP", [2]}),

    {ok,[_]} =
    orax:sql_query(ConnRef, "ALTER DATABASE CLOSE NORMAL"),

    {ok,[_]} =
    orax:sql_query(ConnRef, "ALTER DATABASE DISMOUNT"),

    {ok,[_]} =
    orax:sql_query(ConnRef, {"STOP", [8]}),
    
    ok.

