%% End-to-end encryption broker state (briskd_e2ee). Both tables are Mnesia
%% disc copies and survive restart under every retention policy: losing a
%% device bundle or a queued envelope breaks the clients' Double Ratchet
%% sessions. The server stores only public keys and opaque ciphertext.

%% One published device of an account (X3DH prekey bundle). `key` is
%% {FoldedAccount, DeviceId}. `identity`, `signed_prekey`, and `signature` are
%% the raw bytes of the base64 values the client published; `prekeys` holds
%% the unused one-time prekeys, oldest first. `updated` is microseconds since
%% the epoch; across server links the newer bundle wins. `used` remembers the
%% ids of handed-out one-time prekeys (newest first, at most 1000), so a burst
%% from a peer that missed a `USE` cannot bring a used prekey back.
-record(e2ee_device, {
    key :: {binary(), non_neg_integer()},
    account :: binary(),
    identity :: binary(),
    signed_prekey_id :: non_neg_integer(),
    signed_prekey :: binary(),
    signature :: binary(),
    prekeys = [] :: [{non_neg_integer(), binary()}],
    updated :: integer(),
    used = [] :: [non_neg_integer()]
}).

%% One envelope queued for an offline device until it is acknowledged. Every
%% server of the network keeps a copy (`E2EE QUEUE` over links), so the device
%% can BIND anywhere; an `ACK` removes it everywhere.
%% `key` is {FoldedAccount, DeviceId, Seq}; Seq is a nanosecond timestamp, so
%% the ordered table keeps each device's queue in arrival order and Seq is the
%% queue id (`qid`) the client acknowledges. `expires` is seconds since the
%% epoch.
-record(e2ee_queue, {
    key :: {binary(), non_neg_integer(), non_neg_integer()},
    prefix :: binary(),
    command :: binary(),
    target :: binary(),
    text :: binary() | none | {multiline, [{boolean(), binary()}]},
    tags = [] :: [{binary(), undefined | binary()}],
    expires :: integer()
}).
