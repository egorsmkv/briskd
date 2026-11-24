%% Coherent network-wide population snapshot published in `briskd_population`.
-record(population, {
    local_users = 0 :: non_neg_integer(),
    remote_users = 0 :: non_neg_integer(),
    unknown_users = 0 :: non_neg_integer(),
    invisible_users = 0 :: non_neg_integer(),
    operators = 0 :: non_neg_integer(),
    channels = 0 :: non_neg_integer(),
    servers = 1 :: pos_integer(),
    max_local = 0 :: non_neg_integer(),
    max_global = 0 :: non_neg_integer()
}).
