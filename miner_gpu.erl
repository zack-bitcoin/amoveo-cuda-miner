-module(miner_gpu)
.
-export([start/0, unpack_mining_data/1]).
%-define(Peer, "http://localhost:8081/").%for a full node on same computer.
%-define(Peer, "http://localhost:8085/").%for a mining pool on the same computer.
-define(Peer, "http://24.5.185.238:8085/").%for a mining pool on an external server
-define(CORES, 1).
-define(Pubkey, <<"BIGGeST9w6M//7Bo8iLnqFSrLLnkDXHj9WFFc+kwxeWm2FBBi0NDS0ERROgBiNQqv47wkh0iABPN1/2ECooCTOM=">>).
-define(timeout, 600).%how long to wait in seconds before checking if new mining data is available.
-define(pool_sleep_period, 1000).%How long to wait in miliseconds if we cannot connect to the mining pool.
%This should probably be around 1/20th of the blocktime.

unpack_mining_data(R) ->
    <<_:(8*11), R2/binary>> = list_to_binary(R),
    {First, R3} = slice(R2, hd("\"")),
    <<_:(8*2), R4/binary>> = R3,
    {Second, R5} = slice(R4, hd("\"")),
    <<_:8, R6/binary>> = R5,
    {Third, _} = slice(R6, hd("]")),
    F = base64:decode(First),
    S = base64:decode(Second),
    {F, S, Third}.
start() ->
    io:fwrite("Started mining.\n"),
    start2().
start2() ->
    flush(),
    Data = <<"[\"mining_data\"]">>,
    R = talk_helper(Data, ?Peer, 1000),
    if
	is_list(R) ->
	    start_gpu_miner(R);
	is_atom(R) ->
	    timer:sleep(1000),
	    start()
    end.
read_nonce(0) -> 0;
read_nonce(N) ->
    case file:read_file("nonce.txt") of
	{ok, <<Nonce:256>>} -> Nonce;
	{ok, <<>>} -> 
	    io:fwrite("nonce failed "),
	    io:fwrite(integer_to_list(N)),
	    io:fwrite("\n"),
	    timer:sleep(100),
	    read_nonce(N-1)
    end.

start_gpu_miner(R) ->
    {F, _, Third} = unpack_mining_data(R), %S is the nonce
    RS = crypto:strong_rand_bytes(32),
    ok = file:write_file("nonce.txt", <<"">>),
    file:write_file("mining_input", <<F/binary, RS/binary, Third/binary>>),
    Port = open_port({spawn, "./amoveo_gpu_miner"},[exit_status]),
    receive 
	{Port, {exit_status,1}}->
	    io:fwrite("Found a block. 1\n"),
	    Nonce = read_nonce(1),
            BinNonce = base64:encode(<<Nonce:256>>),
            Data = << <<"[\"work\",\"">>/binary, BinNonce/binary, <<"\",\"">>/binary, ?Pubkey/binary, <<"\"]">>/binary>>,
            talk_helper(Data, ?Peer, 5),
            io:fwrite("Found a block. 2\n"),
            timer:sleep(100);
	{Port, {exit_status,0}}->
	    io:fwrite("did not find a block in that period \n"),
            ok		
    end,
    start2().

talk_helper2(Data, Peer) ->
    httpc:request(post, {Peer, [], "application/octet-stream", iolist_to_binary(Data)}, [{timeout, 3000}], []).
talk_helper(_Data, _Peer, 0) -> throw("talk helper failed");
talk_helper(Data, Peer, N) ->
    case talk_helper2(Data, Peer) of
        {ok, {_Status, _Headers, []}} ->
            io:fwrite("server gave confusing response\n"),
            timer:sleep(?pool_sleep_period),
            talk_helper(Data, Peer, N-1);
        {ok, {_, _, R}} -> R;
        %{error, _} ->
        E -> 
            io:fwrite("\nIf you are running a solo-mining node, then this error may have happened because you need to turn on and sync your Amoveo node before you can mine. You can get it here: https://github.com/zack-bitcoin/amoveo \n If this error happens while connected to the public mining node, then it can probably be safely ignored."),
             timer:sleep(?pool_sleep_period),
             talk_helper(Data, Peer, N-1)
    end.
slice(Bin, Char) ->
    slice(Bin, Char, 0).
slice(Bin, Char, N) ->
    NN = N*8,
    <<First:NN, Char2:8, Second/binary>> = Bin,
    if
        N > size(Bin) -> 1=2;
        (Char == Char2) ->
            {<<First:NN>>, Second};
        true ->
            slice(Bin, Char, N+1)
    end.
flush() ->
    receive
        _ ->
            flush()
    after
        0 ->
            ok
    end.
