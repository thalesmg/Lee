-module(lee_server).

-behaviour(gen_server).

-include_lib("lee/src/framework/lee_internal.hrl").

%% API
-export([ start_link/2
        , start_link/1
        , patch/1
        , get_d/1
        , get/1
        , list/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).

-record(s,
        { model :: lee:model()
        , data  :: lee_storage:storage()
        }).

-type transaction() :: fun((lee:model(), lee:data()) -> {ok, lee:patch()} | abort).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec start_link(lee:model(), lee:patch()) -> {ok, pid()}.
start_link(Model, InitialData) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Model, InitialData], []).

%% @doc Starts the server
-spec start_link(lee:patch()) -> {ok, pid()}.
start_link(InitialData) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [InitialData], []).

%% @doc Safely apply a patch
-spec patch(transaction()) -> ok | {error, term()}.
patch(Fun) ->
    gen_server:call(?SERVER, {patch, Fun}).

%% @doc Get a value via dirty mnesia read
-spec get_d(lee:key()) -> term().
get_d(Key) ->
    %% TODO: optimize these calls (should be constants)
    Model = lee_dirty_mnesia_storage:from_table(?model_table),
    Data = lee_dirty_mnesia_storage:from_table(?data_table),
    lee:get(Model, Data, Key).

%% @doc Get a value via transactional mnesia read (should be called
%% from a mnesia transaction)
-spec get(lee:key()) -> term().
get(Key) ->
    %% TODO: optimize these calls (should be constants)
    Model = lee_mnesia_storage:from_table(?model_table),
    Data = lee_mnesia_storage:from_table(?data_table),
    lee:get(Model, Data, Key).

%% @doc List values (should be run from a mnesia transaction)
-spec list(lee:key()) -> term().
list(Pattern) ->
    %% TODO: optimize these calls (should be constants)
    Model = lee_mnesia_storage:from_table(?model_table),
    Data = lee_mnesia_storage:from_table(?data_table),
    lee:list(Model, Data, Pattern).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([InitialData]) ->
    %% Collect model from the interface_modules:
    InterfaceModules = application:get_env(lee, interface_modules, []),
    Model = gather_model(InterfaceModules),
    init([Model, InitialData]);
init([Model0, InitialData]) ->
    MOpts = #{table_name => ?model_table},
    MMOpts = #{table_name => ?metamodel_table},
    lee_storage:new(lee_mnesia_storage, MOpts),
    lee_storage:new(lee_mnesia_storage, MMOpts),
    {atomic, Model} = mnesia:transaction(
                        fun() ->
                                lee_model:clone( Model0
                                               , lee_mnesia_storage
                                               , MMOpts, MOpts)
                        end),
    Data = lee_storage:new( lee_mnesia_storage
                          , #{table_name => ?data_table}),
    ok = do_patch(fun(_, _) -> {ok, InitialData} end, Model, Data),
    {ok, #s{ model = Model
           , data = Data
           }}.

handle_call({patch, Fun}, _From, S0 = #s{model = M, data = D}) ->
    Reply = do_patch(Fun, M, D),
    {reply, Reply, S0};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec do_patch(transaction(), lee:model(), lee:data()) -> ok | {error, term()}.
do_patch(Fun, M, D) ->
    Ret = mnesia:transaction(
            fun() ->
                    case Fun(M, D) of
                        {ok, Patch} ->
                            lee_storage:patch(D, Patch),
                            case lee:validate(M, D) of
                                {ok, _} ->
                                    ok;
                                {error, Err, Warn} ->
                                    mnesia:abort({invalid_config, Err, Warn})
                            end;
                        abort ->
                            mnesia:abort(user)
                    end
            end),
    case Ret of
        {atomic, ok}      -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

-spec gather_model([module()]) -> lee:model().
gather_model(InterfaceModules) ->
    Models = gather_optional(InterfaceModules, model),
    MetaModels = gather_optional(InterfaceModules, metamodel),
    {ok, Model} = lee_model:compile( [lee:base_metamodel() | MetaModels]
                                   , Models
                                   ),
    Model.

-spec gather_optional([module()], atom()) -> [lee:lee_module()].
gather_optional(Modules, Callback) ->
    [apply(I, Callback, []) || I <- Modules
                             , lists:member( {Callback, 0}
                                           , I:module_info(exports)
                                           )].