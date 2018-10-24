-module(saturn_benchmarks_rpc).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

-record(state, {node,
                clock,
                mydc,
                number_keys,
                id,
                correlation,
                local_buckets,
                remote_buckets,
                ordered_latencies,
                total_dcs,
                buckets_map}).

%% ====================================================================
%% API
%% ====================================================================

new(Id) ->
    Nodes = basho_bench_config:get(saturn_dc_nodes),
    Correlation = basho_bench_config:get(saturn_correlation),
    NumberKeys = basho_bench_config:get(saturn_number_internalkeys),
    MyNode = basho_bench_config:get(saturn_mynode),
    MyDc = basho_bench_config:get(saturn_dc_id),
    BucketsFileName = basho_bench_config:get(saturn_buckets_file),
    TreeFileName = basho_bench_config:get(saturn_tree_file),

    {ok, BucketsFile} = file:open(BucketsFileName, [read]),
    Name = list_to_atom(integer_to_list(Id) ++ atom_to_list(buckets)),
    BucketsMap = ets:new(Name, [set, named_table]),
    {ok, {LocalBuckets, RemoteBuckets}} = get_buckets_from_file(BucketsFile, MyDc, [], [], BucketsMap),
    file:close(BucketsFile),

    {ok, TreeFile} = file:open(TreeFileName, [read]),
    {ok, {LatenciesOrdered, NumberDcs}} = get_tree_from_file(TreeFile, MyDc, 0, []),
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
    Node = lists:nth((Id rem length(Nodes)+1), Nodes),

    Cookie = basho_bench_config:get(saturn_cookie),
    true = erlang:set_cookie(node(), Cookie),
    
    State = #state{node=Node,
                   clock=0,
                   mydc=MyDc,
                   number_keys=NumberKeys,
                   correlation=Correlation,
                   local_buckets=LocalBuckets,
                   remote_buckets=RemoteBuckets,
                   ordered_latencies=LatenciesOrdered,
                   total_dcs=NumberDcs,
                   buckets_map=BucketsMap,
                   id=Id},
    %lager:info("Worker ~p state: ~p", [Id, State]),
    %lager:info("Worker ~p latencies: ~p", [Id, LatenciesOrdered]),
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

get_buckets_from_file(Device, MyDc, Local, Remote, Map) ->
    case file:read_line(Device) of
        eof ->
            {ok, {Local, Remote}};
        {error, Reason} ->
            lager:error("Problem reading ~p file, reason: ~p", [friends_file, Reason]),
            {error, Reason};
        {ok, Line} ->
            [BucketString|ReplicasString] = string:tokens(hd(string:tokens(Line,"\n")), ","),
            {Bucket, []} = string:to_integer(BucketString),
            Replicas = lists:foldl(fun(Replica, Acc) ->
                                    {Int, []} = string:to_integer(Replica),
                                    [Int|Acc]
                                   end, [], ReplicasString),
            %lager:info("Inserted to ets: ~p, ~p", [lists:sort(Replicas), Bucket]),
            true = ets:insert(Map, {lists:sort(Replicas), Bucket}),
            case lists:member(MyDc, Replicas) of
                true ->
                    get_buckets_from_file(Device, MyDc, [Bucket|Local], Remote, Map);
                false ->
                    get_buckets_from_file(Device, MyDc, Local, [Bucket|Remote], Map)
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

run(read, _KeyGen, _ValueGen, #state{node=Node,
                                     clock=Clock0,
                                     number_keys=NumberKeys,
                                     correlation=Correlation,
                                     local_buckets=LocalBuckets,
                                     ordered_latencies=OrderedLatencies,
                                     buckets_map=BucketsMap,
                                     mydc=MyDc,
                                     total_dcs=NumberDcs}=S0) ->
    {ok, Bucket} = case Correlation of
        uniform ->
            pick_local_bucket(uniform, LocalBuckets);
        _ ->
            pick_local_bucket(Correlation, OrderedLatencies, MyDc, NumberDcs, BucketsMap)
    end,
    Key = random:uniform(NumberKeys),
    BKey = {Bucket, Key},
    Result = rpc:call(Node, saturn_leaf, read, [BKey, Clock0]),
    case Result of
        {ok, {_Value, TimeStamp}} ->
            Clock1 = max(TimeStamp, Clock0),
            {ok, S0#state{clock=Clock1}};
        Else ->
            {error, Else}
    end;

run(remote_read, _KeyGen, _ValueGen, #state{node=Node,
                                            clock=Clock0,
                                            number_keys=NumberKeys,
                                            correlation=Correlation,
                                            remote_buckets=RemoteBuckets,
                                            ordered_latencies=OrderedLatencies,
                                            buckets_map=BucketsMap,
                                            total_dcs=NumberDcs}=S0) ->
    {ok, Bucket} = case Correlation of
        uniform ->
            pick_remote_bucket(uniform, RemoteBuckets);
        _ ->
            pick_remote_bucket(Correlation, OrderedLatencies, NumberDcs, BucketsMap)
    end,
    Key = random:uniform(NumberKeys),
    BKey = {Bucket, Key},
    Result = rpc:call(Node, saturn_leaf, read, [BKey, Clock0]),
    case Result of
        {ok, {_Value, TimeStamp}} ->
            Clock1 = max(TimeStamp, Clock0),
            {ok, S0#state{clock=Clock1}};
        Else ->
            {error, Else}
    end;

run(update, _KeyGen, _ValueGen, #state{node=Node,
                                      clock=Clock0,
                                      number_keys=NumberKeys,
                                      correlation=Correlation,
                                      ordered_latencies=OrderedLatencies,
                                      buckets_map=BucketsMap,
                                      mydc=MyDc,
                                      total_dcs=NumberDcs,
                                      local_buckets=LocalBuckets}=S0) ->
    {ok, Bucket} = case Correlation of
        uniform ->
            pick_local_bucket(uniform, LocalBuckets);
        _ ->
            pick_local_bucket(Correlation, OrderedLatencies, MyDc, NumberDcs, BucketsMap)
    end,
    Key = random:uniform(NumberKeys),
    BKey = {Bucket, Key},
    Result = rpc:call(Node, saturn_leaf, update, [BKey, value, Clock0]),
    case Result of
        {ok, Clock1} ->
            {ok, S0#state{clock=Clock1}};
        Else ->
            {error, Else}
    end;

run(remote_update, _KeyGen, _ValueGen, #state{node=Node,
                                             clock=Clock0,
                                             number_keys=NumberKeys,
                                             correlation=Correlation,
                                             remote_buckets=RemoteBuckets,
                                             ordered_latencies=OrderedLatencies,
                                             buckets_map=BucketsMap,
                                             total_dcs=NumberDcs}=S0) ->
    {ok, Bucket} = case Correlation of
        uniform ->
            pick_remote_bucket(uniform, RemoteBuckets);
        _ ->
            pick_remote_bucket(Correlation, OrderedLatencies, NumberDcs, BucketsMap)
    end,
    Key = random:uniform(NumberKeys),
    BKey = {Bucket, Key},
    Result = rpc:call(Node, saturn_leaf, update, [BKey, value, Clock0]),
    case Result of
        {ok, Clock1} ->
            {ok, S0#state{clock=Clock1}};
        Else ->
            {error, Else}
    end.