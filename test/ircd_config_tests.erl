-module(ircd_config_tests).
-include_lib("eunit/include/eunit.hrl").

secret_match_accepts_equal_binaries_test() ->
    ?assert(ircd_config:secret_match(<<"link-secret">>, <<"link-secret">>)).

secret_match_rejects_different_secrets_test() ->
    ?assertNot(ircd_config:secret_match(<<"link-secret">>, <<"link-secreu">>)),
    ?assertNot(ircd_config:secret_match(<<"link-secret">>, <<"link-secret-longer">>)),
    ?assertNot(ircd_config:secret_match(<<"a">>, <<>>)).

secret_match_rejects_non_binaries_test() ->
    ?assertNot(ircd_config:secret_match(null, null)),
    ?assertNot(ircd_config:secret_match(<<"secret">>, null)).
