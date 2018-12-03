-module(saturn_benchmarks_da_occult_temporal_remote_update_force_ratio).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

%% Constants
-define(MAX_ATTEMPTS, 3).
-define(VECTOR_SIZE, 10).       %% Maximum size of the causal timestamp
-define(RESET_DEPS_UPDATE_FREQUENCY, 3).
-define(N_READS, 9).

-record(state, {node,
                nodes,
                mydc,
                id,
                correlation,
                local_buckets,  %% Buckets that the replica masters: [Bucket|Local]
                remote_buckets, %% Buckets that are mastered in other replicas: [ {Bucket, Master} | Remote ]
                all_buckets,    %% Stores all the buckets the replica has
                ordered_latencies,
                total_dcs,
                remote_tx,
                key_tx,
                buckets_map,
                causal_timestamp}).

%% ====================================================================
%% API
%% ====================================================================

new(Id) ->
    Nodes = basho_bench_config:get(saturn_dc_nodes),
    Correlation = basho_bench_config:get(saturn_correlation),
    MyNode = basho_bench_config:get(saturn_mynode),
    MyDc = basho_bench_config:get(saturn_dc_id),
    BucketsFileName = basho_bench_config:get(saturn_buckets_file),
    TreeFileName = basho_bench_config:get(saturn_tree_file),
    RemoteTx = basho_bench_config:get(saturntx_remote_percentage),
    KeyTx = basho_bench_config:get(saturntx_n_key),
    

    {ok, BucketsFile} = file:open(BucketsFileName, [read]),
    Name = list_to_atom(integer_to_list(Id) ++ atom_to_list(buckets)),
    BucketsMap = ets:new(Name, [set, named_table]),
    {ok, {LocalBuckets, RemoteBuckets, AllBuckets}} = get_buckets_from_file(BucketsFile, MyDc, [], [], [], BucketsMap),
    file:close(BucketsFile),

    {ok, TreeFile} = file:open(TreeFileName, [read]),
    {ok, {LatenciesOrdered, _NumberLines}} = get_tree_from_file(TreeFile, MyDc, 0, []),
    %% Quick fix for allowing explicit migration
    NumberDcs = length(Nodes),
    file:close(TreeFile),

    case net_kernel:start(MyNode) of
        {ok, _} ->
            ?INFO("Net kernel started as ~p\n", [node()]);
        {error, {already_started, _}} ->
            ?INFO("Net kernel already started as ~p\n", [node()]),
            ok;
        {error, Reason} ->
            ?FAIL_MSG("Failed to start net_kernel for ~p: ~p\n", [?MODULE, Reason])
    end,
    Node = lists:nth((MyDc rem length(Nodes)+1), Nodes),
    Cookie = basho_bench_config:get(saturn_cookie),
    true = erlang:set_cookie(node(), Cookie),

    ok = ping_each(Nodes),

    case Id of
        1 ->
            ok = rpc:call(Node, saturn_leaf, clean, [MyDc]),
            timer:sleep(5000);
        _ ->
            noop
    end,
    
    State = #state{node=Node,
                   nodes=Nodes,
                   mydc=MyDc,
                   remote_tx=RemoteTx,
                   key_tx=KeyTx,
                   correlation=Correlation,
                   local_buckets=LocalBuckets,
                   remote_buckets=RemoteBuckets,
                   all_buckets=AllBuckets,
                   ordered_latencies=LatenciesOrdered,
                   total_dcs=NumberDcs,
                   buckets_map=BucketsMap,
                   id=Id,
                   causal_timestamp=[]},
    {ok, State}.

get_tree_from_file(Device, MyDc, Counter, OrderedList) ->
    case file:read_line(Device) of
        eof ->
            case (Counter > MyDc) of
                true ->
                    {ok, {OrderedList, Counter}};
                false ->
                    {error, not_enough}
            end;
        {error, Reason} ->
            lager:error("Problem reading ~p file, reason: ~p", [friends_file, Reason]),
            {error, Reason};
        {ok, Line} ->
            case Counter of
                MyDc ->
                    %lager:info("my row: ~p", [Line]),
                    ListString = string:tokens(hd(string:tokens(Line,"\n")), ","),
                    {List, _} = lists:foldl(fun(LatencyString, {Acc, DcId}) ->
                                                {Latency, []} = string:to_integer(LatencyString),
                                                {orddict:store(Latency, DcId, Acc), DcId+1}
                                            end, {orddict:new(), 0}, ListString),
                    get_tree_from_file(Device, MyDc, Counter+1, List);
                _ ->
                    get_tree_from_file(Device, MyDc, Counter+1, OrderedList)
            end
    end.

get_buckets_from_file(Device, MyDc, Local, Remote, All, Map) ->
    case file:read_line(Device) of
        eof ->
            {ok, {Local, Remote, All}};
        {error, Reason} ->
            lager:error("Problem reading ~p file, reason: ~p", [friends_file, Reason]),
            {error, Reason};
        {ok, Line} ->
            [BucketString|ReplicasString] = string:tokens(hd(string:tokens(Line,"\n")), ","),
            %% Get the Bucket
            {Bucket, []} = string:to_integer(BucketString),
            %% Get the master and the slaves
            [MasterString | SlavesString] = ReplicasString,
            {Master, []} = string:to_integer(MasterString),
            Slaves = lists:foldl(fun(Replica, Acc) ->
                {Int, []} = string:to_integer(Replica),
                [Int|Acc]
            end, [], SlavesString),
            true = ets:insert(Map, {[Master] ++ lists:sort(Slaves), Bucket}),    

            %% Debugging
            % lager:info("Bucket: ~p, Master: ~p, Slaves: ~p", [Bucket, Master, Slaves]),

            %% Check if the current bucket is stored in the replica
            All1 = case (MyDc == Master) or (lists:member(MyDc, Slaves)) of
                true ->
                    [Bucket|All];
                false ->
                    All
            end,

            %% Store the Bucket whether it is mastered by MyDc or not
            %% All Buckets will be replicated in the current replica, but, after
            %% failing N times, it goes to the master
            case MyDc == Master of
                true ->
                    get_buckets_from_file(Device, MyDc, [Bucket|Local], Remote, All1, Map);
                false ->
                    get_buckets_from_file(Device, MyDc, Local, [ {Bucket, Master} | Remote ], All1, Map)
            end
    end.

pick_local_bucket(proportional, [_MySelf|LatenciesOrderedDcs], MyDc, NumberDcs, BucketsMap) ->
    Group = get_bucket_proportional(LatenciesOrderedDcs, NumberDcs),
    [{_, Bucket}] = ets:lookup(BucketsMap, lists:sort([MyDc|Group])),
    {ok, Bucket};

pick_local_bucket(exponential, [_MySelf|LatenciesOrderedDcs], MyDc, NumberDcs, BucketsMap) ->
    Group = get_bucket_exponential(LatenciesOrderedDcs, NumberDcs),
    [{_, Bucket}] = ets:lookup(BucketsMap, lists:sort([MyDc|Group])),
    {ok, Bucket}.

pick_local_bucket(uniform, MyBuckets) ->
    Pos = random:uniform(length(MyBuckets)),
    Bucket = lists:nth(Pos, MyBuckets),
    {ok, Bucket}.

%% Does not choose the fully replicated bucket
pick_local_bucket_not_full(MyBuckets, BucketFullReplication) ->
    Pos = random:uniform(length(MyBuckets)),
    Bucket = lists:nth(Pos, MyBuckets),

    case Bucket of
        BucketFullReplication ->
            pick_local_bucket_not_full(MyBuckets, BucketFullReplication);
        _ ->
            {ok, Bucket}
    end.

pick_remote_bucket(proportional, [_MySelf|LatenciesOrderedDcs]=Latencies, NumberDcs, BucketsMap) ->
    case get_bucket_proportional(LatenciesOrderedDcs, NumberDcs) of
        [] ->
            pick_remote_bucket(proportional, Latencies, NumberDcs, BucketsMap);
        Group ->
            [{_, Bucket}] = ets:lookup(BucketsMap, lists:sort(Group)),
            {ok, Bucket}
    end;

pick_remote_bucket(exponential, [_MySelf|LatenciesOrderedDcs]=Latencies, NumberDcs, BucketsMap) ->
    case get_bucket_exponential(LatenciesOrderedDcs, NumberDcs) of
        [] ->
            pick_remote_bucket(exponential, Latencies, NumberDcs, BucketsMap);
        Group ->
            [{_, Bucket}] = ets:lookup(BucketsMap, lists:sort(Group)),
            {ok, Bucket}
    end.

pick_remote_bucket(uniform, RemoteBuckets) ->
    Pos = random:uniform(length(RemoteBuckets)),
    Bucket = lists:nth(Pos, RemoteBuckets),
    {ok, Bucket}.

get_bucket_proportional(LatenciesOrderedDcs, NumberDcs) ->    
    {_, DCs} = lists:foldl(fun({_Latency, DC}, {Counter, List}) ->
                            Portion = trunc(100/NumberDcs),
                            Prob = (NumberDcs-Counter)*Portion,
                            case random:uniform(100) =< Prob of
                                true ->
                                    {Counter + 1, [DC|List]};
                                false ->
                                    {Counter + 1, List}
                            end
                           end, {1, []}, LatenciesOrderedDcs),
    DCs.

get_bucket_exponential(LatenciesOrderedDcs, NumberDcs) ->    
    {_ ,DCs} = lists:foldl(fun({_Latency, DC}, {Counter, List}) ->
                            Max = math:pow(2, NumberDcs),
                            Upper = math:pow(2, (NumberDcs - Counter)) * 100,
                            Prob = trunc(Upper/Max),
                            case random:uniform(100) =< Prob of
                                true ->
                                    {Counter + 1, [DC|List]};
                                false ->
                                    {Counter + 1, List}
                            end
                           end, {1, []}, LatenciesOrderedDcs),
    DCs.

get_bkeys(0, _KeyGen, BKeys, _S0) ->
    BKeys;

get_bkeys(Rest, KeyGen, BKeys, S0=#state{remote_tx=PercentageRemote,
                                 correlation=Correlation,
                                 local_buckets=LocalBuckets,
                                 remote_buckets=RemoteBuckets,
                                 ordered_latencies=OrderedLatencies,
                                 buckets_map=BucketsMap,
                                 mydc=MyDc,
                                 total_dcs=NumberDcs}) ->
    Type = case (PercentageRemote>random:uniform(100)) of
        true -> remote;
        false -> local
    end,
    {ok, Bucket} = case {Type, Correlation} of
        {local, uniform} ->
            pick_local_bucket(uniform, LocalBuckets);
        {remote, uniform} ->
            pick_remote_bucket(uniform, RemoteBuckets);
        {local, _} ->
            pick_local_bucket(Correlation, OrderedLatencies, MyDc, NumberDcs, BucketsMap);
        {remote, _} ->
            pick_remote_bucket(Correlation, OrderedLatencies, NumberDcs, BucketsMap);
        {_, full} ->
            {ok, trunc(math:pow(2,NumberDcs) - 2)}
    end,
    Key = generate_key(KeyGen, Bucket, BKeys),
    get_bkeys(Rest-1, KeyGen, [{Bucket, Key}|BKeys], S0).

generate_key(KeyGen, Bucket, BKeys) -> 
    Key = KeyGen(),
    case lists:member({Bucket, Key}, BKeys) of
        true ->
            generate_key(KeyGen, Bucket, BKeys);
        false ->
            Key
    end.

run(read, KeyGen, _ValueGen, S0) ->
    read_sequence(KeyGen, S0);

run(remote_read, KeyGen, _ValueGen, S0=#state{nodes=Nodes,
                                              buckets_map=BucketsMap,
                                              total_dcs=NumberDcs,
                                              mydc=MyDc}) ->

    %% Choose new replica
    Id = get_random_dc_id(MyDc, NumberDcs),
    Node = get_node_from_id(Id, NumberDcs, Nodes),
    BKey = {Id, KeyGen()},
    {LocalBuckets, RemoteBuckets, AllBuckets, LatenciesOrdered} = update_local_dc(Id, BucketsMap),


    %% Make the request to the local replica
    read(BKey, Node, S0#state{mydc=Id,
                              node=Node,
                              local_buckets=LocalBuckets,
                              remote_buckets=RemoteBuckets,
                              all_buckets=AllBuckets,
                              ordered_latencies=LatenciesOrdered});

run(update, KeyGen, ValueGen, S0) ->
    {Attempts, S1} = gather_deps(KeyGen, ValueGen, S0),
    update_reset(KeyGen, ValueGen, S1).

%% ====================================================================
%% Internal functions
%% ====================================================================

ping_each([]) ->
    ok;
ping_each([Node | Rest]) ->
    case net_adm:ping(Node) of
        pong ->
            ping_each(Rest);
        pang ->
            ?FAIL_MSG("Failed to ping node ~p\n", [Node])
    end.

server_name(Node)->
    {saturn_client_receiver, Node}.
    %{global, list_to_atom(atom_to_list(Node) ++ atom_to_list(saturn_client_receiver))}.

get_node_from_id(Id, NumberDcs, Nodes) ->
    lists:nth((Id rem NumberDcs+1), Nodes).

update_local_dc(Id, BucketsMap) ->
    %% Update local and remote buckets
    BucketsFileName = basho_bench_config:get(saturn_buckets_file),
    {ok, BucketsFile} = file:open(BucketsFileName, [read]),
    ets:delete_all_objects(BucketsMap),
    {ok, {LocalBuckets, RemoteBuckets, AllBuckets}} = get_buckets_from_file(BucketsFile, Id, [], [], [], BucketsMap),
    file:close(BucketsFile),

    %% Update ordered latencies
    TreeFileName = basho_bench_config:get(saturn_tree_file),
    {ok, TreeFile} = file:open(TreeFileName, [read]),
    {ok, {LatenciesOrdered, _NumberLines}} = get_tree_from_file(TreeFile, Id, 0, []),
    file:close(TreeFile),

    {LocalBuckets, RemoteBuckets, AllBuckets, LatenciesOrdered}.

%% Start of get_different_id/3
get_different_id(MyDc, Id, NumberDcs) ->
    get_different_id_tail(MyDc, Id, NumberDcs, 0).

get_different_id_tail(MyDc, Id, NumberDcs, Index) ->
    case Index < NumberDcs of
        true ->
            case (Index == MyDc) or (Index == Id) of
                true ->
                    get_different_id_tail(MyDc, Id, NumberDcs, Index + 1);
                false ->
                    {ok, Index}
            end;
        false ->
            {error, "Impossible to get a different Id."}
    end.
%% End of get_different_id/3

%% Start of get_random_dc_id/2
get_random_dc_id(MyDc, NumberDcs) ->
    get_random_dc_id_tail(MyDc, NumberDcs, random:uniform(NumberDcs) - 1).

get_random_dc_id_tail(MyDc, NumberDcs, NewDc) ->
    case MyDc == NewDc of
        true ->
            get_random_dc_id_tail(MyDc, NumberDcs, random:uniform(NumberDcs) - 1);
        false ->
            NewDc
    end.
%% End of get_random_dc_id/2

%% Taken from saturn_utilities
now_microsec()->
    %% Not very efficient. os:timestamp() faster but non monotonic. Test!
    {MegaSecs, Secs, MicroSecs} = os:timestamp(),
    (MegaSecs * 1000000 + Secs) * 1000000 + MicroSecs.

%% After writes, it must receive an empty dictionary
insert_dep({BKey, Version}, Deps) ->
    case dict:find(BKey, Deps) of
        {ok, Value} ->
            dict:store(BKey, max(Version, Value), Deps);
        error ->
            dict:store(BKey, Version, Deps)
    end.

log_state(State) ->
    lager:info("Worker ~p state:~nNode:~p~nNodes:~p~nClock:~p~nMyDC:~p~nRemote_TX:~p~nKey_TX:~p~nCorrelation:~p~nLocal_Buckets:~p~nRemote_Buckets:~p~nOrdered_Latencies:~p~nTotalDCs:~p~nBuckets_Map:~p",
    [State#state.id,
     State#state.node,
     State#state.nodes,
     State#state.mydc,
     State#state.remote_tx,
     State#state.key_tx,
     State#state.correlation,
     State#state.local_buckets,
     State#state.remote_buckets,
     State#state.ordered_latencies,
     State#state.total_dcs,
     State#state.buckets_map]).

%% Choosing a bucket that is partially replicated
pick_bucket_partial_replication(BucketFullReplication, S0=#state{correlation=Correlation,
                                                                 ordered_latencies=OrderedLatencies,
                                                                 buckets_map=BucketsMap,
                                                                 mydc=MyDc,
                                                                 total_dcs=NumberDcs,
                                                                 local_buckets=LocalBuckets}) ->

    %% Choose a bucket as previously
    {ok, Bucket} = case Correlation of
        uniform ->
            pick_local_bucket(uniform, LocalBuckets);
        full ->
            {ok, trunc(math:pow(2, NumberDcs) - 2)};
        _ ->
            pick_local_bucket(Correlation, OrderedLatencies, MyDc, NumberDcs, BucketsMap)
    end,

    %% Try again if the bucket is the same as the fully replicated one
    case Bucket of
        BucketFullReplication ->
            pick_bucket_partial_replication(BucketFullReplication, S0);
        _ ->
            {ok, Bucket}
    end.

%% Operations
read_sequence(KeyGen, S0=#state{node=Node,
                                all_buckets=AllBuckets}) ->

    %% Start counting the time
    % Start = now_microsec(),

    %% Pick BKey
    {ok, Bucket} = pick_local_bucket(uniform, AllBuckets),
    BKey = {Bucket, KeyGen()},

    %% Make the request to the local replica
    Output = read(BKey, Node, S0),

    %% Output the operation latency
    % lager:info("\nREAD LATENCY: ~p MICROS", [now_microsec() - Start]),

    Output.

%% Update, but keep the previous dependencies
update_keep_dep(KeyGen, ValueGen, S0=#state{node=Node,
                                            nodes=Nodes,
                                            total_dcs=NumberDcs,
                                            local_buckets=LocalBuckets,
                                            remote_buckets=RemoteBuckets,
                                            all_buckets=AllBuckets,
                                            causal_timestamp=CausalTimestamp0}) ->

    %% Start counting the time
    % Start = now_microsec(),

    %% Pick the BKey
    BucketFullReplication = hd(AllBuckets),
    {ok, Bucket} = pick_local_bucket_not_full(AllBuckets, BucketFullReplication),
    BKey = {Bucket, KeyGen()},

    %% Get the master of the BKey shard
    UpdateNode = case lists:member(Bucket, LocalBuckets) of
        true ->
            Node;
        false ->
            MasterId = get_master_id(BKey, RemoteBuckets),
            get_node_from_id(MasterId, NumberDcs, Nodes)
    end,

    %% Make the request to the master replica
    Result = gen_server:call(server_name(UpdateNode), {update, BKey, ValueGen(), CausalTimestamp0, now_microsec()}, infinity),
    Output = case Result of
        {ok, ShardStampResponse} ->
            {ok, S0#state{causal_timestamp=merge_causal_timestamps(CausalTimestamp0, [{ShardStampResponse, Bucket}])}};
        Else ->
            {error, Else}
    end,
    
    %% Output the operation latency 
    % lager:info("\nUPDATE (NOT RESET) LATENCY: ~p MICROS", [now_microsec() - Start]),

    Output.

%% Update to the special partition
update_reset(KeyGen, ValueGen, S0=#state{node=Node,
                                         nodes=Nodes,
                                         total_dcs=NumberDcs,
                                         local_buckets=LocalBuckets,
                                         remote_buckets=RemoteBuckets,
                                         all_buckets=AllBuckets,
                                         causal_timestamp=CausalTimestamp0}) ->

    %% Start counting the time
    % Start = now_microsec(),

    %% Pick BKey
    Bucket = hd(AllBuckets),
    BKey = {Bucket, KeyGen()},

    %% Get the master of the BKey shard
    UpdateNode = case lists:member(Bucket, LocalBuckets) of
        true ->
            Node;
        false ->
            MasterId = get_master_id(BKey, RemoteBuckets),
            get_node_from_id(MasterId, NumberDcs, Nodes)
    end,

    %% Make the request to the master replica
    Result = gen_server:call(server_name(UpdateNode), {update, BKey, ValueGen(), CausalTimestamp0, now_microsec()}, infinity),
    Output = case Result of
        {ok, ShardStampResponse} ->
            {ok, S0#state{causal_timestamp=merge_causal_timestamps(CausalTimestamp0, [{ShardStampResponse, Bucket}])}};
        Else ->
            {error, Else}
    end,
    
    %% Output the operation latency 
    % lager:info("\nUPDATE (WITH RESET) LATENCY: ~p MICROS", [now_microsec() - Start]),

    Output.

%% Makes the sequence of reads and update_keep_deps
gather_deps(KeyGen, ValueGen, S0) ->
    gather_deps(KeyGen, ValueGen, 0, 0, S0).
gather_deps(KeyGen, ValueGen, NUpdates, NReads, S0) ->
    %% Check if it is a read
    case NReads < ?N_READS of
        true ->
            {ok, Attempts, S1} = read_sequence(KeyGen, S0),
            {TotalTemp, S2} = gather_deps(KeyGen, ValueGen, NUpdates, NReads + 1, S1),
            {TotalTemp + Attempts, S2};
        false ->
            %% Check if it is a non-reset update
            case NUpdates < ?RESET_DEPS_UPDATE_FREQUENCY of
                true ->
                    {ok, S1} = update_keep_dep(KeyGen, ValueGen, S0),
                    gather_deps(KeyGen, ValueGen, NUpdates + 1, 0, S1);
                false ->
                    {0, S0}
            end
    end.

%%%%%%%%%%%%%%%%%%%%%%
%% OCCULT UTILITIES %%
%%%%%%%%%%%%%%%%%%%%%%

get_master_id({Bucket, _}, [ {Bucket, MasterId} | _]) ->
    MasterId;

get_master_id(BKey, [ _ | Rem]) ->
    get_master_id(BKey, Rem).

%%%%%%%%%%%%%%%%
%% OCCULT API %%
%%%%%%%%%%%%%%%%
read(BKey, Node, S0) ->
    read(BKey, Node, 0, S0).    

read(BKey={Bucket, _}, Node, Attempt, S0=#state{total_dcs=NumberDcs,
                                                nodes=Nodes,
                                                causal_timestamp=CausalTimestamp0,
                                                local_buckets=LocalBuckets,
                                                remote_buckets=RemoteBuckets}) ->

    case Attempt < ?MAX_ATTEMPTS of
        %% Try the local replica
        true ->
            case gen_server:call(server_name(Node), {read, BKey}, infinity) of
                {ok, {_Value, CausalTimeStampResponse, ShardStampResponse}} ->
                    %% Get the client's shardstamp
                    ShardStampClient = get_client_shardstamp(Bucket, CausalTimestamp0),

                    %% Check if this is a valid response or if the current node is the master
                    case (ShardStampResponse >= ShardStampClient) or lists:member(Bucket, LocalBuckets) of
                        %% This is a valid response
                        true ->
                            {ok, Attempt, S0#state{causal_timestamp=merge_causal_timestamps(CausalTimestamp0, CausalTimeStampResponse)}};

                        %% Try again
                        false ->
                            read(BKey, Node, Attempt + 1, S0)
                    end;
                Else ->
                    {error, Else}
            end;

        %% Go the the master
        false ->
            %% Get the master node address
            MasterId = get_master_id(BKey, RemoteBuckets),
            MasterNode = get_node_from_id(MasterId, NumberDcs, Nodes),

            %% Make the call that is guaranteed to succeed
            case gen_server:call(server_name(MasterNode), {read, BKey}, infinity) of
                {ok, {_Value, CausalTimeStampResponse, _ShardStampResponse}} ->
                    {ok, Attempt, S0#state{causal_timestamp=merge_causal_timestamps(CausalTimestamp0, CausalTimeStampResponse)}};
                Else ->
                    {error, Else}
            end
    end.

%% Needed for the temporal compression technique
merge_causal_timestamps(LocalTimestamp, ReceivedTimestamp) ->
    merge_causal_timestamps(LocalTimestamp, ReceivedTimestamp, [], 0, []).

merge_causal_timestamps(_, _, Result, ?VECTOR_SIZE, _) ->
    lists:reverse(Result);

merge_causal_timestamps([], [], Result, _, _) ->
    lists:reverse(Result);

merge_causal_timestamps([LocalEntry={_, Shard} | LocalRem], [], Result, Size, ExistingShards) ->
    %% Check if the shard already belongs to the vector in construction
    case lists:member(Shard, ExistingShards) of
        true ->
            merge_causal_timestamps(LocalRem, [], Result, Size, ExistingShards);
        false ->
            merge_causal_timestamps(LocalRem, [], [LocalEntry] ++ Result, Size + 1, [Shard] ++ ExistingShards)
    end;

merge_causal_timestamps([], [ReceivedEntry={_, Shard} | ReceivedRem], Result, Size, ExistingShards) ->
    %% Check if the shard already belongs to the vector in construction
    case lists:member(Shard, ExistingShards) of
        true ->
            merge_causal_timestamps([], ReceivedRem, Result, Size, ExistingShards);
        false ->
            merge_causal_timestamps([], ReceivedRem, [ReceivedEntry] ++ Result, Size + 1, [Shard] ++ ExistingShards)
    end;

merge_causal_timestamps(LocalTimestamp=[LocalEntry={LocalShardstamp, LocalShard} | LocalRem],
                        ReceivedTimestamp=[ReceivedEntry={ReceivedShardstamp, ReceivedShard} | ReceivedRem],
                        Result,
                        Size,
                        ExistingShards) ->

    case ReceivedShardstamp > LocalShardstamp of
        true ->
            %% Check if the shard already belongs to the vector in construction
            case lists:member(ReceivedShard, ExistingShards) of
                true ->
                    merge_causal_timestamps(LocalTimestamp, ReceivedRem, Result, Size, ExistingShards);
                false ->
                    merge_causal_timestamps(LocalTimestamp, ReceivedRem, [ReceivedEntry] ++ Result, Size + 1, [ReceivedShard] ++ ExistingShards)
            end;
        false ->
            %% Check if the shard already belongs to the vector in construction
            case lists:member(LocalShard, ExistingShards) of
                true ->
                    merge_causal_timestamps(LocalRem, ReceivedTimestamp, Result, Size, ExistingShards);
                false ->
                    merge_causal_timestamps(LocalRem, ReceivedTimestamp, [LocalEntry] ++ Result, Size + 1, [LocalShard] ++ ExistingShards)
            end
    end.

%% It will force an acceptance of the causal timestamp
get_client_shardstamp(_, []) ->
    0;

%% This is the catch-all entry
get_client_shardstamp(_, [{Shardstamp, _} | [] ]) ->
    Shardstamp;

get_client_shardstamp(Bucket, [ {Shardstamp, BucketClient} | Rem]) ->
    case Bucket == BucketClient of
        true ->
            Shardstamp;
        false ->
            get_client_shardstamp(Bucket, Rem)
    end.
