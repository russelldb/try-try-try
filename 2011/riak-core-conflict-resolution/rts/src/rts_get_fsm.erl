%% @doc The coordinator for stat get operations.  The key here is to
%% generate the preflist just like in wrtie_fsm and then query each
%% replica and wait until a quorum is met.
-module(rts_get_fsm).
-behavior(gen_fsm).
-include("rts.hrl").

%% API
-export([start_link/4, get/2]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([prepare/2, execute/2, waiting/2]).

-record(state, {req_id,
                from,
                client,
                stat_name,
                preflist,
                num_r=0,
                num_nf=0,
                replies=[]}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqID, From, Client, StatName) ->
    gen_fsm:start_link(?MODULE, [ReqID, From, Client, StatName], []).

get(Client, StatName) ->
    ReqID = mk_reqid(),
    rts_get_fsm_sup:start_get_fsm([ReqID, self(), Client, StatName]),
    {ok, ReqID}.

%%%===================================================================
%%% States
%%%===================================================================

%% Intiailize state data.
init([ReqId, From, Client, StatName]) ->
    SD = #state{req_id=ReqId,
                from=From,
                client=Client,
                stat_name=StatName},
    {ok, prepare, SD, 0}.

%% @doc Calculate the Preflist.
prepare(timeout, SD0=#state{client=Client,
                            stat_name=StatName}) ->
    DocIdx = riak_core_util:chash_key({list_to_binary(Client),
                                       list_to_binary(StatName)}),
    Prelist = riak_core_apl:get_apl(DocIdx, ?N, rts_stat),
    SD = SD0#state{preflist=Prelist},
    {next_state, execute, SD, 0}.

%% @doc Execute the get reqs.
execute(timeout, SD0=#state{req_id=ReqId,
                            stat_name=StatName,
                            preflist=Prelist}) ->
    rts_stat_vnode:get(Prelist, ReqId, StatName),
    {next_state, waiting, SD0}.

%% @doc Wait for R replies and then respond to From (original client
%% that called `rts:get/2').
waiting({ok, ReqID, Val}, SD0=#state{from=From}) ->
    SD=#state{replies=Replies} = update_state(Val, SD0),
    case check_quorum(SD) of
        r_met ->
            Reply = hd(Replies),
            From ! {ReqID, ok, Reply},
            {stop, normal, SD};
        n_met ->
            Reply = not_found,
            From ! {ReqID, ok, Reply},
            {stop, normal, SD};
        not_met -> {next_state, waiting, SD}
    end.

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

update_state(not_found, SD=#state{num_nf=NumNF}) ->
    SD#state{num_nf=NumNF+1};
update_state(Val, SD=#state{num_r=NumR, replies=Replies}) ->
    SD#state{num_r=NumR+1,replies=[Val|Replies]}.

check_quorum(#state{num_r=NumR}) when NumR >= ?R ->
    r_met;
check_quorum(#state{num_r=NumR, num_nf=NumNF}) when (NumR + NumNF) =:=  ?N ->
    n_met;
check_quorum(_) ->
    not_met.

mk_reqid() -> erlang:phash2(erlang:now()).
