-module(lobby).
-behavior(gen_server).

-include("../include/reversi.hrl").

%% API
-export([
         start_link/0
         , client_command/1
         , game_over/2
         , game_crash/4
        ]).

%% Info API
-export([
         get_game/1,
         list_games/0,
         list_bots/0,
         get_bot/1
        ]).

%% gen_server callbacks
-export([
         init/1,
         code_change/3,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2
        ]).

-record(lobby_state,
        {
        }).


%%% API

start_link() ->
    gen_server:start_link({local, reversi_lobby}, ?MODULE, [], []).

%% This functions is called by the client handler.
client_command(Command) ->
    gen_server:call(reversi_lobby, {cmd, Command}).

game_over(Game, Winner) ->
    gen_server:cast(reversi_lobby, {game_over, Game, Winner}).

game_crash(Reason, Game, Black, White) ->
    gen_server:cast(reversi_lobby,
                    {game_server_crash, Reason, Game, Black, White}).

get_game(GameId) ->
    gen_server:call(reversi_lobby, {get_game, GameId}).

list_games() ->
    gen_server:call(reversi_lobby, {list_games}).

list_bots() ->
    gen_server:call(reversi_lobby, {list_bots}).

get_bot(BotName) ->
    gen_server:call(reversi_lobby, {get_bot, BotName}).

%%% gen_server callbacks

init(_Args) ->
    {ok, #lobby_state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call({get_game, GameID}, _From, State) ->
    case lobby_db:read_game(GameID) of
        [#duel{game_server=GameServer}] ->
            {reply, game_server:status(GameServer), State};
        [] ->
            {reply, rev_game_db:get_game(GameID), State}
    end;

handle_call({list_games}, _From, State) ->
    Current = [Id || #duel{game_id = Id} <- lobby_db:list_games()],
    {ok, Previous} = rev_game_db:list_games(),
    GameIds = lists:merge(lists:sort(Current), lists:sort(Previous)),
    {reply, {ok, GameIds}, State};

handle_call({list_bots}, _From, State) ->
    {reply, {ok, rev_bot:list_bots()}, State};

handle_call({get_bot, BotName}, _From, State) ->
    try
        Bot = rev_bot:read(BotName),
        {reply, {ok, Bot}, State}
    catch
        _:_ -> {reply, {error, no_such_bot}, State}
    end;

handle_call({cmd, Command}, From, State) ->
    handle_client_command(Command, From, State);
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({game_over, #game{id = ID} = G, Winner}, LS) ->
    rev_game_db:update_game(G#game{end_time = now()}),
    lobby_db:delete_game(ID),
    update_ranking(G, Winner),
    {noreply, LS};
handle_cast({game_crash, Game, _Black, _White}, LS) ->
    %% TODO: Remove game from database (or store crash info?)
    lobby_db:delete_game_server(Game),
    {noreply, LS};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.


%%% Internal functions

handle_client_command({Help, _IP}, _From, State) when Help =:= {help} orelse Help =:= help ->
    {reply, help_text, State};

handle_client_command({{commands}, _IP}, _From, State) ->
    {reply, detailed_help_text, State};

handle_client_command({{game, GameID, Command}, _IP}, From, State) ->
    case lobby_db:read_game(GameID) of
        [G = #duel{}] ->
            handle_client_game_command(G, From, Command, State);
        [] ->
            {reply, {error, unknown_game}, State}
    end;

handle_client_command({{login, User, Passwd}, IP}, {From, _}, State) ->
    check_inputs,
    case rev_bot:login(User, Passwd, IP) of
        {ok, _} ->
            ok = lobby_db:add_player(From, User),
            {reply, {ok, welcome}, State};
        Error   ->
            {reply, Error, State}
    end;

handle_client_command({{logout}, _IP}, {From,_}, State) ->
    lobby_db:delete_player(From),
    {reply, good_bye, State};

handle_client_command({{register, User, Player, Desc, Email}, IP},
                      {From, _}, State) ->
    check_inputs,
    case rev_bot:register(User, Player, Desc, Email, IP, []) of
        {ok, PW} ->
            lobby_db:add_player(From, User),
            {reply, {ok, {password, PW}}, State};
        Error    ->
            {reply, Error, State}
    end;

handle_client_command({{i_want_to_play}, _IP}, {From, _}, State) ->
    case lobby_db:find_ready_player() of
        [#player{pid=OtherPlayer, name=OtherName}] ->
            #player{name=Name} = lobby_db:read_player(From),
            %% Opponent found, set up a new game!
            {ok, Game} = rev_game_db:new_game(OtherName, Name),
            GameID = Game#game.id,
            B = cookie(),
            W = cookie(),
            {ok, GameServer} = game_server_sup:start_game_server(GameID,B,W),
            G = #duel{game_id = GameID,
                      game_server = GameServer,
                      game_data = Game#game{start_time = now()},
                      black = B,
                      white = W
                     },
            lobby_db:add_game(G),
            gen_server:cast(OtherPlayer,
                            {redirect, {lets_play, GameServer, ?B, GameID, B}}),
            {reply, {redirect, {lets_play, GameServer, ?W, GameID, W}}, State};
        [] ->
            lobby_db:add_ready_player(From),
            {reply, {ok, waiting_for_challenge}, State}
    end;

handle_client_command(_Command, _From, LS) ->
    {reply, {error, unknown_command}, LS}.


handle_client_game_command(#duel{}, _From, _Command, LS) ->
    {reply, {error, unknown_game_command}, LS}.

cookie() ->
    <<A:64>> = crypto:rand_bytes(8),
    A.

update_ranking(#game{player_b = B, player_w = W}, ?B) ->
    {BotA, BotB} = calc_rank(rev_bot:read(B), rev_bot:read(W), 1, 0),
    rev_bot:write(BotA),
    rev_bot:write(BotB);
update_ranking(#game{player_b = B, player_w = W}, ?W) ->
    {BotA, BotB} = calc_rank(rev_bot:read(W), rev_bot:read(B), 0, 1),
    rev_bot:write(BotA),
    rev_bot:write(BotB);
update_ranking(#game{player_b = B, player_w = W}, ?E) ->
    {BotA, BotB} = calc_rank(rev_bot:read(W), rev_bot:read(B), 0.5, 0.5),
    rev_bot:write(BotA),
    rev_bot:write(BotB).


calc_rank(#rev_bot{rank = Ra} = A, #rev_bot{rank = Rb} = B, ScoreA, ScoreB) ->
    Qa = math:pow(10, Ra/400),
    Qb = math:pow(10, Rb/400),
    Ea = Qa / (Qa + Qb),
    Eb = Qb / (Qa + Qb),

    %% ranking = old ranking + 32*(score - Expected score).
    NewRa = Ra + round(32 * (ScoreA - Ea)),
    NewRb = Rb + round(32 * (ScoreB - Eb)),
    %%io:format("A: ~p, B: ~p~n", [(ScoreA - Ea),(ScoreB - Eb)]),
    {A#rev_bot{rank = NewRa}, B#rev_bot{rank = NewRb}}.
