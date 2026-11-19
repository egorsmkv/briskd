%% End-to-end encryption broker state (ircd_e2ee). Both tables are Mnesia
%% disc copies and survive restart under every retention policy: losing a
%% device bundle or a queued envelope breaks the clients' Double Ratchet
%% sessions. The server stores only public keys and opaque ciphertext.

%% One published device of an account (X3DH prekey bundle). `key` is
%% {FoldedAccount, DeviceId}. `identity`, `signed_prekey`, and `signature` are
%% the raw bytes of the base64 values the client published; `prekeys` holds
%% the unused one-time prekeys, oldest first. `updated` is seconds since the
%% epoch.
-record(e2ee_device, {
    key :: {binary(), non_neg_integer()},
    account :: binary(),
    identity :: binary(),
    signed_prekey_id :: non_neg_integer(),
    signed_prekey :: binary(),
    signature :: binary(),
    prekeys = [] :: [{non_neg_integer(), binary()}],
    updated :: integer()
}).

%% One envelope queued for an offline device until it is acknowledged.
%% `key` is {FoldedAccount, DeviceId, Seq}; Seq is a nanosecond timestamp, so
%% the ordered table keeps each device's queue in arrival order and Seq is the
%% queue id (`qid`) the client acknowledges. `expires` is seconds since the
%% epoch.
-record(e2ee_queue, {
    key :: {binary(), non_neg_integer(), non_neg_integer()},
    prefix :: binary(),
    command :: binary(),
    target :: binary(),
    text :: binary() | none,
    tags = [] :: [{binary(), undefined | binary()}],
    expires :: integer()
}).
