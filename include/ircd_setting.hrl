%% A runtime override of one configuration setting, made in the admin panel
%% (ircd_overrides). `key` names the control ("chathistory",
%% "features.reactions", ...); `value` is what replaces the configuration
%% file's value. Durable: it survives REHASH and restarts.
-record(setting, {key :: binary(), value :: boolean() | integer()}).
