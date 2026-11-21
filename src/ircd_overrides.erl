-module(ircd_overrides).
-moduledoc """
Admin overrides of server features: settings an administrator changes in the
WebUI admin panel without editing the configuration file.

Each control names one setting the server already applies live: a chat
feature (`features.*`), history, account options, a configured subsystem
(`e2ee`, `calls`, `voice`, `files`, `search`: on means the file's section,
off means none), DroneBL, or a limit. An override replaces the file's value; the
effective configuration is the file's with the overrides applied
(`apply/2`), computed at startup and on every `REHASH`, so an override
survives both. Overrides are rows of the durable Mnesia `setting` table.
`ircd_state` is the only writer and applies a change through the same path
as `REHASH`, which advertises or withdraws capabilities (`CAP NEW`/`DEL`).
A subsystem that is not configured in the file cannot be turned on here.
""".
-export([
    all/0,
    apply/2,
    available/2,
    delete/1,
    describe/3,
    effective/3,
    find/1,
    put/2,
    validate/2
]).
-export_type([control/0, value/0]).

-include("ircd_state.hrl").

-type value() :: boolean() | integer().
-type kind() :: boolean | {integer, integer(), integer()}.
-type path() ::
    {top, atom()} | {feature, atom()} | {section, atom()} | dronebl.
-type control() :: #{key := binary(), group := binary(), kind := kind(), path := path()}.

%% The controls, in the order the admin panel shows them.
-spec controls() -> [control()].
controls() ->
    Feature = fun(K) ->
        #{
            key => <<"features.", (atom_to_binary(K))/binary>>,
            group => <<"chat">>,
            kind => boolean,
            path => {feature, K}
        }
    end,
    Top = fun(K, Group, Kind) ->
        #{key => atom_to_binary(K), group => Group, kind => Kind, path => {top, K}}
    end,
    Section = fun(K) ->
        #{key => atom_to_binary(K), group => <<"services">>, kind => boolean, path => {section, K}}
    end,
    [Feature(K) || K <- [reactions, replies, typing, editing, redaction, link_previews]] ++
        [
            Top(chathistory, <<"history">>, boolean),
            Top(history_limit, <<"history">>, {integer, 1, 10000}),
            Top(account_registration, <<"accounts">>, boolean),
            Top(account_registration_before_connect, <<"accounts">>, boolean),
            Top(account_registration_email_required, <<"accounts">>, boolean),
            Top(multiclient, <<"accounts">>, boolean),
            Top(account_rejoin, <<"accounts">>, boolean),
            Top(max_accounts, <<"accounts">>, {integer, 1, 1000000}),
            Section(e2ee),
            Section(calls),
            Section(voice),
            Section(files),
            Section(search),
            #{key => <<"dronebl">>, group => <<"security">>, kind => boolean, path => dronebl},
            Top(utf8_only, <<"security">>, boolean),
            Top(monitor_limit, <<"limits">>, {integer, 1, 1000000}),
            Top(resource_delay, <<"limits">>, {integer, 0, 86400})
        ].

-doc "The control named `Key`, or `error`.".
-spec find(binary()) -> {ok, control()} | error.
find(Key) ->
    case [C || #{key := K} = C <- controls(), K =:= Key] of
        [Control] -> {ok, Control};
        [] -> error
    end.

-doc """
Parse `Text` as a value for the control `Key`: `true`/`false` for a switch,
a decimal integer within the control's bounds (inclusive) for a limit.
""".
-spec validate(binary(), binary()) -> {ok, value()} | {error, unknown_control | invalid_value}.
validate(Key, Text) ->
    case find(Key) of
        error ->
            {error, unknown_control};
        {ok, #{kind := boolean}} when Text =:= <<"true">> ->
            {ok, true};
        {ok, #{kind := boolean}} when Text =:= <<"false">> ->
            {ok, false};
        {ok, #{kind := {integer, Min, Max}}} ->
            try binary_to_integer(Text) of
                N when N >= Min, N =< Max -> {ok, N};
                _ -> {error, invalid_value}
            catch
                error:badarg -> {error, invalid_value}
            end;
        {ok, _} ->
            {error, invalid_value}
    end.

-doc """
The effective configuration: the file's `Base` with `Overrides` applied.
Unknown keys (a control removed in a later version) are ignored; turning on
a subsystem the file does not configure leaves it off.
""".
-spec apply(ircd_config:config(), #{binary() => value()}) -> ircd_config:config().
apply(Base, Overrides) ->
    effective(Base, Base, Overrides).

-doc """
`Current` with every control's setting taken from `Base` and `Overrides`:
used when an override changes, so settings outside the controls (a log
level set with `ircdctl`) stay as they are.
""".
-spec effective(ircd_config:config(), ircd_config:config(), #{binary() => value()}) ->
    ircd_config:config().
effective(Current, Base, Overrides) ->
    lists:foldl(
        fun(#{key := Key, path := Path}, Acc) ->
            Value =
                case Overrides of
                    #{Key := V} -> V;
                    #{} -> get(Path, Base)
                end,
            set(Path, Value, Acc, Base)
        end,
        Current,
        controls()
    ).

-doc """
The controls for the admin panel: each one's group, kind and bounds, the
effective value, the configuration file's value, whether an override is
set, and whether it can be changed (a subsystem must be configured).
""".
-spec describe(ircd_config:config(), ircd_config:config(), #{binary() => value()}) -> [map()].
describe(Current, Base, Overrides) ->
    [
        maps:merge(
            #{
                key => Key,
                group => Group,
                value => get(Path, Current),
                default => get(Path, Base),
                overridden => is_map_key(Key, Overrides),
                available => path_available(Path, Base)
            },
            kind_fields(Kind)
        )
     || #{key := Key, group := Group, kind := Kind, path := Path} <- controls()
    ].

kind_fields(boolean) -> #{type => <<"boolean">>};
kind_fields({integer, Min, Max}) -> #{type => <<"integer">>, min => Min, max => Max}.

-doc """
Whether the control `Key` can be changed with the configuration file `Base`:
a subsystem (`e2ee`, `calls`, `voice`, `files`) only when the file sets it up.
""".
-spec available(binary(), ircd_config:config()) -> boolean().
available(Key, Base) ->
    case find(Key) of
        {ok, #{path := Path}} -> path_available(Path, Base);
        error -> false
    end.

path_available({section, K}, Base) -> maps:get(K, Base, null) =/= null;
path_available(_, _) -> true.

get({top, K}, Config) ->
    maps:get(K, Config);
get({feature, K}, Config) ->
    maps:get(K, maps:get(features, Config, #{}), true);
get({section, K}, Config) ->
    maps:get(K, Config, null) =/= null;
get(dronebl, Config) ->
    maps:get(enabled, maps:get(dronebl, Config, #{}), false).

set({top, K}, V, Config, _Base) ->
    Config#{K => V};
set({feature, K}, V, Config, _Base) ->
    Config#{features => (maps:get(features, Config, #{}))#{K => V}};
set({section, K}, true, Config, Base) ->
    Config#{K => maps:get(K, Base, null)};
set({section, K}, false, Config, _Base) ->
    Config#{K => null};
set(dronebl, V, Config, _Base) ->
    Config#{dronebl => (maps:get(dronebl, Config, #{}))#{enabled => V}}.

-doc "Every stored override, by control key.".
-spec all() -> #{binary() => value()}.
all() ->
    Tables =
        case mnesia:system_info(tables) of
            List when is_list(List) -> List;
            _ -> []
        end,
    case lists:member(setting, Tables) of
        true ->
            maps:from_list([
                {Key, Value}
             || Key <- ircd_state:table_keys(setting),
                [#setting{value = Value}] <- [mnesia:dirty_read(setting, Key)]
            ]);
        false ->
            #{}
    end.

-doc "Store the override `Value` for the control `Key`. Call from `m:ircd_state`.".
-spec put(binary(), value()) -> ok.
put(Key, Value) ->
    mnesia:dirty_write(#setting{key = ircd_wire:retain(Key), value = Value}).

-doc "Remove the override for `Key`, so the file's value applies again.".
-spec delete(binary()) -> ok.
delete(Key) ->
    mnesia:dirty_delete(setting, Key).
