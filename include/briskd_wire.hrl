%% IRC line limits. An untagged line is at most 512 octets including the
%% trailing CR LF (RFC 1459 section 2.3, RFC 2812 section 2.3). A tagged line
%% may add an IRCv3 tag section of at most 8191 octets (`@`, at most 4094
%% bytes of tag data, and the separating space) in front of that line.
%% Buffered input with no line end is capped separately.

%% Untagged line, CR LF included.
-define(MAX_UNTAGGED_LINE, 512).
%% Bytes available before the CR LF.
-define(MAX_LINE_BEFORE_CRLF, (?MAX_UNTAGGED_LINE - 2)).
%% Bytes available before ` :` and the CR LF of a trailing parameter.
-define(MAX_LINE_BEFORE_TRAILING, (?MAX_UNTAGGED_LINE - 4)).
%% Tag data, not counting `@` or the separating space.
-define(MAX_TAG_DATA, 4094).
%% `@`, the tag data, and the separating space.
-define(MAX_TAG_SECTION, 8191).
%% Longest accepted line: one tag section plus one untagged line.
-define(MAX_WIRE_LINE, (?MAX_TAG_SECTION + ?MAX_UNTAGGED_LINE)).
%% Cap one socket delivery before it is appended to a partial line.
-define(MAX_PENDING_BYTES, 1048576).
