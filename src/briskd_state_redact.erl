-module(briskd_state_redact).
-moduledoc """
OTP `format_status/1` secret redaction for `m:briskd_state`.

Replaces credentials in `PASS`, `OPER`, `AUTHENTICATE`, `REGISTER`, `VERIFY`,
`RECLAIM`, `WEBIRC`, and account control calls with `redacted` in both the
current message and the `sys` debug log. Pure.
""".
-export([format_status/1, redact_command/1]).

-doc """
Redact secrets from an OTP `gen_server` `format_status/1` map.
""".
-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun redact_status/2, Status).

redact_status(message, Message) ->
    redact_command(Message);
redact_status(log, Log) when is_list(Log) ->
    [redact_log_event(Event) || Event <- Log];
redact_status(_, Value) ->
    Value.

redact_log_event({Type, Message}) ->
    {Type, redact_command(Message)};
redact_log_event({Type, Message, Extra}) ->
    {Type, redact_command(Message), Extra};
redact_log_event(Event) ->
    Event.

-doc """
Redact secret parameters from a single message or `gen_server` call term.
""".
-spec redact_command(term()) -> term().
redact_command({'$gen_call', From, Request}) ->
    {'$gen_call', From, redact_command(Request)};
redact_command({ctl, {create_account, Name, _Password, Email}}) ->
    {ctl, {create_account, Name, redacted, Email}};
redact_command({command_as, Primary, Command, Params, Bytes, Tags}) ->
    {command, _, Redacted, _, _} = redact_command({command, Command, Params, Bytes, Tags}),
    {command_as, Primary, Command, Redacted, Bytes, Tags};
redact_command({command, <<"RECLAIM">>, [_Secret | Rest], Bytes, Tags}) ->
    {command, <<"RECLAIM">>, [redacted | Rest], Bytes, Tags};
redact_command({command, <<"RECLAIM">>, [_Secret | Rest], Bytes}) ->
    {command, <<"RECLAIM">>, [redacted | Rest], Bytes};
redact_command({command, <<"PASS">>, [_Password | Rest], Bytes, Tags}) ->
    {command, <<"PASS">>, [redacted | Rest], Bytes, Tags};
redact_command({command, <<"PASS">>, [_Password | Rest], Bytes}) ->
    {command, <<"PASS">>, [redacted | Rest], Bytes};
redact_command({command, <<"OPER">>, [Name, _Password | Rest], Bytes, Tags}) ->
    {command, <<"OPER">>, [Name, redacted | Rest], Bytes, Tags};
redact_command({command, <<"OPER">>, [Name, _Password | Rest], Bytes}) ->
    {command, <<"OPER">>, [Name, redacted | Rest], Bytes};
redact_command({command, <<"AUTHENTICATE">>, [_ | _], Bytes, Tags}) ->
    {command, <<"AUTHENTICATE">>, [redacted], Bytes, Tags};
redact_command({command, <<"AUTHENTICATE">>, [_ | _], Bytes}) ->
    {command, <<"AUTHENTICATE">>, [redacted], Bytes};
redact_command({command, <<"REGISTER">>, [Account, Email, _Password | Rest], Bytes, Tags}) ->
    {command, <<"REGISTER">>, [Account, Email, redacted | Rest], Bytes, Tags};
redact_command({command, <<"REGISTER">>, [Account, Email, _Password | Rest], Bytes}) ->
    {command, <<"REGISTER">>, [Account, Email, redacted | Rest], Bytes};
redact_command({signup_account, Account, Email, _Password, PeerIP}) ->
    {signup_account, Account, Email, redacted, PeerIP};
redact_command({verify_account, Account, _Code}) ->
    {verify_account, Account, redacted};
redact_command({verify_account_by_email, Email, _Code}) ->
    {verify_account_by_email, Email, redacted};
redact_command({complete_password_reset, Email, _Code, _NewPassword, PeerIP}) ->
    {complete_password_reset, Email, redacted, redacted, PeerIP};
redact_command({ctl, {reset_password, Name, _Password}}) ->
    {ctl, {reset_password, Name, redacted}};
redact_command({command, <<"VERIFY">>, [Account, _Code | Rest], Bytes, Tags}) ->
    {command, <<"VERIFY">>, [Account, redacted | Rest], Bytes, Tags};
redact_command({command, <<"VERIFY">>, [Account, _Code | Rest], Bytes}) ->
    {command, <<"VERIFY">>, [Account, redacted | Rest], Bytes};
redact_command({command, <<"WEBIRC">>, [_Password | Rest], Bytes, Tags}) ->
    {command, <<"WEBIRC">>, [redacted | Rest], Bytes, Tags};
redact_command({command, <<"WEBIRC">>, [_Password | Rest], Bytes}) ->
    {command, <<"WEBIRC">>, [redacted | Rest], Bytes};
redact_command(Message) ->
    Message.
