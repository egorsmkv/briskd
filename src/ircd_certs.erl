-module(ircd_certs).
-behaviour(gen_server).
-export([
    start_link/1,
    check_now/0,
    check_async/0,
    validate_pair/2,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-moduledoc """
Reload TLS certificates when their files change, without a restart.

Certificates from an ACME client such as [lego](https://go-acme.github.io/lego/)
(see the [Deployment guide](deployment.html)) are renewed every few weeks.
This process watches the configured `certfile`/`keyfile` pair and every `sni`
pair. Every `tls_reload_interval` seconds (configuration, default 60; `0`
turns the watcher off) it reads the files and compares their SHA-256 digest
with the last loaded one. When they changed:

1. each pair is validated with `validate_pair/2`: both files parse as PEM, the
   first certificate is the leaf, and the private key matches its public key
   (RSA and EC keys; other key types are checked for parsing only). A
   half-written or mismatched pair is rejected and logged once
   (`cert_reload_rejected`); the next check tries again;
2. the OTP PEM cache is cleared (`ssl:clear_pem_cache/0`), so STARTTLS
   upgrades and new handshakes read the new files;
3. the `tls` and `wss` listeners are restarted under `ircd_sup` so their
   listen sockets load the new certificate. Established connections keep
   their sessions; only new handshakes see the new certificate. The listeners
   bind the same configured ports again (`reuseaddr`).

Each reload logs `cert_reloaded` with the leaf certificate's names (its DNS
subject alternative names, or the subject CN when it has none) and expiry. `REHASH` asks for an immediate check (`check_async/0`).

The process runs only when a TLS or secure WebSocket listener is configured.
It reads files and calls `ircd_sup`; it holds no protocol state and never
calls `ircd_state`.
""".

-include_lib("public_key/include/public_key.hrl").

-define(RESTARTED, [tls, wss]).

-doc "Start the watcher for the TLS files in `Config` (see the moduledoc).".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc """
Check the files now and reload when they changed. Returns `unchanged`,
`reloaded`, or `{error, Reason}` when the new files were rejected.
""".
-spec check_now() -> unchanged | reloaded | {error, term()}.
check_now() ->
    gen_server:call(?MODULE, check, 30000).

-doc "Ask for a check without waiting (used by `REHASH`); a no-op when the watcher is off.".
-spec check_async() -> ok.
check_async() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, check)
    end.

-doc """
Validate a certificate and private key file pair. Returns `{ok, Info}` with
the leaf certificate's `names` (DNS subject alternative names, or the subject
CN) and `not_after` (ISO 8601 UTC), or
`{error, Reason}`: `{unreadable, File, Posix}`, `{no_certificate, File}`,
`{no_key, File}`, `{bad_pem, File}`, or `key_mismatch`.
""".
-spec validate_pair(file:filename(), file:filename()) ->
    {ok, #{names := binary(), not_after := binary()}} | {error, term()}.
validate_pair(CertFile, KeyFile) ->
    maybe
        {ok, CertPem} ?= read(CertFile),
        {ok, KeyPem} ?= read(KeyFile),
        {ok, Der} ?= leaf_der(CertFile, CertPem),
        {ok, Key} ?= private_key(KeyFile, KeyPem),
        Cert = public_key:pkix_decode_cert(Der, otp),
        true ?= key_matches(Cert, Key) orelse {error, key_mismatch},
        {ok, describe(Cert)}
    end.

%%% gen_server

-doc false.
init(Config) ->
    Pairs = pairs(maps:get(tls_options, Config, [])),
    Interval = maps:get(tls_reload_interval, Config, 60),
    State = #{pairs => Pairs, interval => Interval, digest => digest(Pairs), rejected => none},
    {ok, schedule(State)}.

-doc false.
handle_call(check, _From, State) ->
    {Result, Next} = check(State),
    {reply, Result, Next};
handle_call(_, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc false.
handle_cast(check, State) ->
    {_, Next} = check(State),
    {noreply, Next};
handle_cast(_, State) ->
    {noreply, State}.

-doc false.
handle_info({check, Ref}, #{timer := Ref} = State) ->
    {_, Next} = check(State),
    {noreply, schedule(Next)};
%% A stale timer from before a reschedule, or an unknown message.
handle_info(_, State) ->
    {noreply, State}.

%%% Internal

schedule(#{interval := 0} = State) ->
    State#{timer => undefined};
schedule(#{interval := Seconds} = State) ->
    Ref = make_ref(),
    erlang:send_after(Seconds * 1000, self(), {check, Ref}),
    State#{timer => Ref}.

check(#{pairs := Pairs, digest := Old} = State) ->
    case digest(Pairs) of
        Old ->
            {unchanged, State};
        New ->
            case validate_all(Pairs) of
                {ok, Infos} ->
                    reload(),
                    lists:foreach(
                        fun(Info) -> logger:notice(Info#{event => cert_reloaded}) end, Infos
                    ),
                    {reloaded, State#{digest := New, rejected := none}};
                {error, Reason} = Error ->
                    %% Log a given bad set of files once, not on every tick.
                    case maps:get(rejected, State) of
                        New -> ok;
                        _ -> logger:warning(#{event => cert_reload_rejected, reason => Reason})
                    end,
                    {Error, State#{rejected := New}}
            end
    end.

validate_all(Pairs) ->
    lists:foldl(
        fun
            ({Cert, Key}, {ok, Infos}) ->
                case validate_pair(Cert, Key) of
                    {ok, Info} -> {ok, [Info#{certfile => list_to_binary(Cert)} | Infos]};
                    {error, _} = Error -> Error
                end;
            (_, Error) ->
                Error
        end,
        {ok, []},
        Pairs
    ).

reload() ->
    ok = ssl:clear_pem_cache(),
    lists:foreach(
        fun(Kind) ->
            case supervisor:terminate_child(ircd_sup, Kind) of
                ok ->
                    case supervisor:restart_child(ircd_sup, Kind) of
                        {ok, _} ->
                            ok;
                        Error ->
                            logger:error(#{
                                event => listener_restart_failed, transport => Kind, reason => Error
                            })
                    end;
                {error, not_found} ->
                    ok
            end
        end,
        ?RESTARTED
    ).

%% The main pair first, then each SNI pair, as file name strings.
pairs(Options) ->
    Main =
        case {proplists:get_value(certfile, Options), proplists:get_value(keyfile, Options)} of
            {Cert, Key} when Cert =/= undefined, Key =/= undefined -> [{Cert, Key}];
            _ -> []
        end,
    Sni = [
        {proplists:get_value(certfile, Host), proplists:get_value(keyfile, Host)}
     || {_Name, Host} <- proplists:get_value(sni_hosts, Options, [])
    ],
    Main ++ Sni.

%% One digest over every watched file; an unreadable file counts as a change
%% (validation then reports it) rather than crashing the watcher.
digest(Pairs) ->
    crypto:hash(sha256, [
        case file:read_file(File) of
            {ok, Bin} -> [File, 0, Bin];
            {error, Reason} -> [File, 1, atom_to_list(Reason)]
        end
     || {Cert, Key} <- Pairs, File <- [Cert, Key]
    ]).

read(File) ->
    case file:read_file(File) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, {unreadable, unicode:characters_to_binary(File), Reason}}
    end.

leaf_der(File, Pem) ->
    case pem_entries(File, Pem) of
        {ok, Entries} ->
            case [Der || {'Certificate', Der, not_encrypted} <- Entries] of
                [Leaf | _] -> {ok, Leaf};
                [] -> {error, {no_certificate, unicode:characters_to_binary(File)}}
            end;
        Error ->
            Error
    end.

private_key(File, Pem) ->
    case pem_entries(File, Pem) of
        {ok, Entries} ->
            Keys = [
                Entry
             || {Type, _, not_encrypted} = Entry <- Entries,
                lists:member(Type, ['RSAPrivateKey', 'ECPrivateKey', 'PrivateKeyInfo'])
            ],
            case Keys of
                [Entry | _] ->
                    try
                        {ok, public_key:pem_entry_decode(Entry)}
                    catch
                        _:_ -> {error, {bad_pem, unicode:characters_to_binary(File)}}
                    end;
                [] ->
                    {error, {no_key, unicode:characters_to_binary(File)}}
            end;
        Error ->
            Error
    end.

pem_entries(File, Pem) ->
    try
        {ok, public_key:pem_decode(Pem)}
    catch
        _:_ -> {error, {bad_pem, unicode:characters_to_binary(File)}}
    end.

%% The private key belongs to the certificate's public key.
key_matches(Cert, Key) ->
    Spki = Cert#'OTPCertificate'.tbsCertificate#'OTPTBSCertificate'.subjectPublicKeyInfo,
    case {Spki#'OTPSubjectPublicKeyInfo'.subjectPublicKey, Key} of
        {#'RSAPublicKey'{modulus = N, publicExponent = E}, #'RSAPrivateKey'{
            modulus = N, publicExponent = E
        }} ->
            true;
        {#'ECPoint'{point = Point}, #'ECPrivateKey'{publicKey = Point}} ->
            true;
        %% An RSA or EC certificate needs its own key, of the same type.
        {#'RSAPublicKey'{}, _} ->
            false;
        {#'ECPoint'{}, _} ->
            false;
        %% Other key types (for example Ed25519): parsed, not compared.
        _ ->
            true
    end.

describe(Cert) ->
    Tbs = Cert#'OTPCertificate'.tbsCertificate,
    #'Validity'{notAfter = NotAfter} = Tbs#'OTPTBSCertificate'.validity,
    Names =
        case dns_names(Tbs) of
            [] -> subject(Tbs#'OTPTBSCertificate'.subject);
            Dns -> iolist_to_binary(lists:join(<<",">>, Dns))
        end,
    #{names => Names, not_after => time_text(NotAfter)}.

dns_names(#'OTPTBSCertificate'{extensions = Extensions}) when is_list(Extensions) ->
    lists:append([
        [unicode:characters_to_binary(Name) || {dNSName, Name} <- Values]
     || #'Extension'{extnID = ?'id-ce-subjectAltName', extnValue = Values} <- Extensions
    ]);
dns_names(_) ->
    [].

subject({rdnSequence, Rdns}) ->
    Parts = [
        Value
     || Set <- Rdns,
        #'AttributeTypeAndValue'{type = ?'id-at-commonName', value = Raw} <- Set,
        Value <- [attribute_text(Raw)]
    ],
    iolist_to_binary(lists:join(<<",">>, Parts)).

attribute_text({_, Text}) when is_list(Text) -> unicode:characters_to_binary(Text);
attribute_text({_, Text}) when is_binary(Text) -> Text;
attribute_text(Text) when is_list(Text) -> unicode:characters_to_binary(Text);
attribute_text(Text) when is_binary(Text) -> Text;
attribute_text(_) -> <<"?">>.

%% X.509 utcTime is YYMMDDHHMMSSZ (years 1950-2049); generalTime is
%% YYYYMMDDHHMMSSZ. Both become YYYY-MM-DDTHH:MM:SSZ.
time_text({utcTime, [Y1, Y2 | Rest]}) ->
    Century =
        case list_to_integer([Y1, Y2]) >= 50 of
            true -> "19";
            false -> "20"
        end,
    time_text({generalTime, Century ++ [Y1, Y2 | Rest]});
time_text({generalTime, [Y1, Y2, Y3, Y4, Mo1, Mo2, D1, D2, H1, H2, Mi1, Mi2, S1, S2 | _]}) ->
    list_to_binary([
        Y1, Y2, Y3, Y4, $-, Mo1, Mo2, $-, D1, D2, $T, H1, H2, $:, Mi1, Mi2, $:, S1, S2, $Z
    ]);
time_text({_, Other}) ->
    unicode:characters_to_binary(Other).
