%% Cap one socket delivery before it is appended to a partial IRC line.
%% Individual lines remain limited to 512 octets by the wire parser.
-define(MAX_PENDING_BYTES, 1048576).
