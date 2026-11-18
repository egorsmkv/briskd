%% Cap one socket delivery before it is appended to a partial IRC line.
%% An untagged IRC line stays within 512 octets. A tagged line may add an
%% IRCv3 tag section of at most 8191 octets, including '@' and the separating
%% space, in front of that 512-octet command.
-define(MAX_PENDING_BYTES, 1048576).
-define(MAX_WIRE_LINE, 8703).
