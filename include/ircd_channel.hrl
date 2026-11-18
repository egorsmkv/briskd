%% Local channel record. Ordinary channels are transient; safe channels persist.
-record(channel, {
    key,
    name,
    topic = <<>>,
    members = #{},
    flags = #{},
    lists = #{},
    invited = [],
    limit,
    password,
    creator,
    opless_since
}).
