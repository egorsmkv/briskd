%% Bounds shared by an outbound peer (`briskd_link`) and an inbound peer
%% (`briskd_session`). The two directions use the same batch, read buffer,
%% send queue, and liveness timers (RFC 2813 section 5.1).

%% Lines of one read passed to briskd_state in one call.
-define(LINK_MAX_BATCH, 2000).
%% Driver read buffer, in bytes, once the socket is an authenticated link.
-define(LINK_READ_BUFFER, 262144).
%% Lines queued toward the peer before the link is dropped.
-define(LINK_MAX_SENDQ, 50000).
%% Quiet time before PING, and how long a matching PONG may take.
-define(LINK_PING_AFTER_MS, 60000).
-define(LINK_PONG_TIMEOUT_MS, 30000).
