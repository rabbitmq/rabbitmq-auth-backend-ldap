%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_auth_backend_ldap).

%% Connect to an LDAP server for authentication and authorisation

-include_lib("eldap/include/eldap.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(rabbit_authn_backend).
-behaviour(rabbit_authz_backend).

-export([user_login_authentication/2, user_login_authorization/1,
         check_vhost_access/3, check_resource_access/3, check_topic_access/4]).

-export([get_connections/0]).

%% for tests
-export([purge_connections/0]).

-define(L(F, A),  log("LDAP "         ++ F, A)).
-define(L1(F, A), log("    LDAP "     ++ F, A)).
-define(L2(F, A), log("        LDAP " ++ F, A)).
-define(SCRUBBED_CREDENTIAL,  "xxxx").
-define(RESOURCE_ACCESS_QUERY_VARIABLES, [username, user_dn, vhost, resource, name, permission]).

-import(rabbit_misc, [pget/2]).

-record(impl, { user_dn, password }).

%%--------------------------------------------------------------------

get_connections() ->
    worker_pool:submit(ldap_pool, fun() -> get(ldap_conns) end, reuse).

purge_connections() ->
    [ok = worker_pool:submit(ldap_pool,
                             fun() -> purge_conn(Anon, Servers, Opts) end, reuse)
     || {{Anon, Servers, Opts}, _} <- maps:to_list(get_connections())],
    ok.

user_login_authentication(Username, []) ->
    %% Without password, e.g. EXTERNAL
    ?L("CHECK: passwordless login for ~s", [Username]),
    R = with_ldap(creds(none),
                  fun(LDAP) -> do_login(Username, unknown, none, LDAP) end),
    ?L("DECISION: passwordless login for ~s: ~p",
       [Username, log_result(R)]),
    R;

user_login_authentication(Username, AuthProps) when is_list(AuthProps) ->
    case pget(password, AuthProps) of
        undefined -> user_login_authentication(Username, []);
        <<>> ->
            %% Password "" is special in LDAP, see
            %% https://tools.ietf.org/html/rfc4513#section-5.1.2
            ?L("CHECK: unauthenticated login for ~s", [Username]),
            ?L("DECISION: unauthenticated login for ~s: denied", [Username]),
            {refused, "user '~s' - unauthenticated bind not allowed", [Username]};
        PW ->
            ?L("CHECK: login for ~s", [Username]),
            R = case dn_lookup_when() of
                    prebind -> UserDN = username_to_dn_prebind(Username),
                               with_ldap({ok, {UserDN, PW}},
                                         login_fun(Username, UserDN, PW, AuthProps));
                    _       -> with_ldap({ok, {fill_user_dn_pattern(Username), PW}},
                                         login_fun(Username, unknown, PW, AuthProps))
                end,
            ?L("DECISION: login for ~s: ~p", [Username, log_result(R)]),
            R
    end;

user_login_authentication(Username, AuthProps) ->
    exit({unknown_auth_props, Username, AuthProps}).

user_login_authorization(Username) ->
    case user_login_authentication(Username, []) of
        {ok, #auth_user{impl = Impl, tags = Tags}} -> {ok, Impl, Tags};
        Else                                       -> Else
    end.

check_vhost_access(User = #auth_user{username = Username,
                                     impl     = #impl{user_dn = UserDN}},
                   VHost, _Sock) ->
    Args = [{username, Username},
            {user_dn,  UserDN},
            {vhost,    VHost}],
    ?L("CHECK: ~s for ~s", [log_vhost(Args), log_user(User)]),
    R = evaluate_ldap(env(vhost_access_query), Args, User),
    ?L("DECISION: ~s for ~s: ~p",
       [log_vhost(Args), log_user(User), log_result(R)]),
    R.

check_resource_access(User = #auth_user{username = Username,
                                        impl     = #impl{user_dn = UserDN}},
                      #resource{virtual_host = VHost, kind = Type, name = Name},
                      Permission) ->
    Args = [{username,   Username},
            {user_dn,    UserDN},
            {vhost,      VHost},
            {resource,   Type},
            {name,       Name},
            {permission, Permission}],
    ?L("CHECK: ~s for ~s", [log_resource(Args), log_user(User)]),
    R = evaluate_ldap(env(resource_access_query), Args, User),
    ?L("DECISION: ~s for ~s: ~p",
       [log_resource(Args), log_user(User), log_result(R)]),
    R.

check_topic_access(User = #auth_user{username = Username,
                                     impl     = #impl{user_dn = UserDN}},
                   #resource{virtual_host = VHost, kind = topic = Resource, name = Name},
                   Permission,
                   Context) ->
    OptionsArgs = topic_context_as_options(Context),
    Args = [{username,   Username},
            {user_dn,    UserDN},
            {vhost,      VHost},
            {resource,   Resource},
            {name,       Name},
            {permission, Permission}] ++ OptionsArgs,
    ?L("CHECK: ~s for ~s", [log_resource(Args), log_user(User)]),
    R = evaluate_ldap(env(topic_access_query), Args, User),
    ?L("DECISION: ~s for ~s: ~p",
        [log_resource(Args), log_user(User), log_result(R)]),
    R.

%%--------------------------------------------------------------------

topic_context_as_options(Context) when is_map(Context) ->
    % filter keys that would erase fixed variables
    [{rabbit_data_coercion:to_atom(Key), maps:get(Key, Context)}
        || Key <- maps:keys(Context),
        lists:member(
            rabbit_data_coercion:to_atom(Key),
            ?RESOURCE_ACCESS_QUERY_VARIABLES) =:= false];
topic_context_as_options(_) ->
    [].

evaluate(Query, Args, User, LDAP) ->
    ?L1("evaluating query: ~p", [Query]),
    evaluate0(Query, Args, User, LDAP).

evaluate0({constant, Bool}, _Args, _User, _LDAP) ->
    ?L1("evaluated constant: ~p", [Bool]),
    Bool;

evaluate0({for, [{Type, Value, SubQuery}|Rest]}, Args, User, LDAP) ->
    case pget(Type, Args) of
        undefined -> {error, {args_do_not_contain, Type, Args}};
        Value     -> ?L1("selecting subquery ~s = ~s", [Type, Value]),
                     evaluate(SubQuery, Args, User, LDAP);
        _         -> evaluate0({for, Rest}, Args, User, LDAP)
    end;

evaluate0({for, []}, _Args, _User, _LDAP) ->
    {error, {for_query_incomplete}};

evaluate0({exists, DNPattern}, Args, _User, LDAP) ->
    %% eldap forces us to have a filter. objectClass should always be there.
    Filter = eldap:present("objectClass"),
    DN = fill(DNPattern, Args),
    R = object_exists(DN, Filter, LDAP),
    ?L1("evaluated exists for \"~s\": ~p", [DN, R]),
    R;

evaluate0({in_group, DNPattern}, Args, User, LDAP) ->
    evaluate({in_group, DNPattern, "member"}, Args, User, LDAP);

evaluate0({in_group, DNPattern, Desc}, Args,
          #auth_user{impl = #impl{user_dn = UserDN}}, LDAP) ->
    Filter = eldap:equalityMatch(Desc, UserDN),
    DN = fill(DNPattern, Args),
    R = object_exists(DN, Filter, LDAP),
    ?L1("evaluated in_group for \"~s\": ~p", [DN, R]),
    R;

evaluate0({in_group_nested, DNPattern}, Args, User, LDAP) ->
	evaluate({in_group_nested, DNPattern, "member", subtree},
             Args, User, LDAP);
evaluate0({in_group_nested, DNPattern, Desc}, Args, User, LDAP) ->
    evaluate({in_group_nested, DNPattern, Desc, subtree},
             Args, User, LDAP);
evaluate0({in_group_nested, DNPattern, Desc, Scope}, Args,
          #auth_user{impl = #impl{user_dn = UserDN}}, LDAP) ->
    GroupsBase = case env(group_lookup_base) of
        none -> env(dn_lookup_base);
        B    -> B
    end,
    GroupDN = fill(DNPattern, Args),
    EldapScope =
        case Scope of
            subtree      -> eldap:wholeSubtree();
            singlelevel  -> eldap:singleLevel();
            single_level -> eldap:singleLevel();
            onelevel     -> eldap:singleLevel();
            one_level    -> eldap:singleLevel()
        end,
    search_nested_group(LDAP, Desc, GroupsBase, EldapScope, UserDN, GroupDN, []);

evaluate0({'not', SubQuery}, Args, User, LDAP) ->
    R = evaluate(SubQuery, Args, User, LDAP),
    ?L1("negated result to ~s", [R]),
    not R;

evaluate0({'and', Queries}, Args, User, LDAP) when is_list(Queries) ->
    R = lists:foldl(fun (Q,  true)    -> evaluate(Q, Args, User, LDAP);
                        % Treat any non-true result as false
                        (_Q, _Result) -> false
                    end, true, Queries),
    ?L1("'and' result: ~s", [R]),
    R;

evaluate0({'or', Queries}, Args, User, LDAP) when is_list(Queries) ->
    R = lists:foldl(fun (_Q, true)    -> true;
                        % Treat any non-true result as false
                        (Q,  _Result) -> evaluate(Q, Args, User, LDAP)
                    end, false, Queries),
    ?L1("'or' result: ~s", [R]),
    R;

evaluate0({equals, StringQuery1, StringQuery2}, Args, User, LDAP) ->
    safe_eval(fun (String1, String2) ->
                      R  = if String1 =:= String2 -> true;
                              true -> is_multi_attr_member(String1, String2)
                           end,
                      ?L1("evaluated equals \"~s\", \"~s\": ~s",
                          [format_multi_attr(String1),
                           format_multi_attr(String2), R]),
                      R
              end,
              evaluate(StringQuery1, Args, User, LDAP),
              evaluate(StringQuery2, Args, User, LDAP));

evaluate0({match, {string, _} = StringQuery, {string, _} = REQuery}, Args, User, LDAP) ->
    safe_eval(fun (String1, String2) ->
                      do_match(String1, String2)
              end,
              evaluate(StringQuery, Args, User, LDAP),
              evaluate(REQuery, Args, User, LDAP));

evaluate0({match, StringQuery, {string, _} = REQuery}, Args, User, LDAP) when is_list(StringQuery)->
    safe_eval(fun (String1, String2) ->
        do_match(String1, String2)
              end,
        evaluate(StringQuery, Args, User, LDAP),
        evaluate(REQuery, Args, User, LDAP));

evaluate0({match, {string, _} = StringQuery, REQuery}, Args, User, LDAP) when is_list(REQuery) ->
    safe_eval(fun (String1, String2) ->
        do_match(String1, String2)
              end,
        evaluate(StringQuery, Args, User, LDAP),
        evaluate(REQuery, Args, User, LDAP));

evaluate0({match, StringQuery, REQuery}, Args, User, LDAP) when is_list(StringQuery),
                                                                is_list(REQuery)  ->
    safe_eval(fun (String1, String2) ->
        do_match(String1, String2)
              end,
        evaluate(StringQuery, Args, User, LDAP),
        evaluate(REQuery, Args, User, LDAP));

evaluate0({match, StringQuery, REQuery}, Args, User, LDAP) ->
    safe_eval(fun (String1, String2) ->
        do_match_bidirectionally(String1, String2)
              end,
        evaluate(StringQuery, Args, User, LDAP),
        evaluate(REQuery, Args, User, LDAP));

evaluate0(StringPattern, Args, User, LDAP) when is_list(StringPattern) ->
    evaluate0({string, StringPattern}, Args, User, LDAP);

evaluate0({string, StringPattern}, Args, _User, _LDAP) ->
    R = fill(StringPattern, Args),
    ?L1("evaluated string for \"~s\"", [R]),
    R;

evaluate0({attribute, DNPattern, AttributeName}, Args, _User, LDAP) ->
    DN = fill(DNPattern, Args),
    R = attribute(DN, AttributeName, LDAP),
    ?L1("evaluated attribute \"~s\" for \"~s\": ~p",
        [AttributeName, DN, format_multi_attr(R)]),
    R;

evaluate0(Q, Args, _User, _LDAP) ->
    {error, {unrecognised_query, Q, Args}}.

search_groups(LDAP, Desc, GroupsBase, Scope, DN) ->
    Filter = eldap:equalityMatch(Desc, DN),
    case eldap:search(LDAP,
                      [{base, GroupsBase},
                       {filter, Filter},
                       {attributes, ["dn"]},
                       {scope, Scope}]) of
        {error, _} = E ->
            ?L("error searching for parent groups for \"~s\": ~p", [DN, E]),
            [];
        {ok, #eldap_search_result{entries = []}} ->
            [];
        {ok, #eldap_search_result{entries = Entries}} ->
            [ON || #eldap_entry{object_name = ON} <- Entries]
    end.

search_nested_group(LDAP, Desc, GroupsBase, Scope, CurrentDN, TargetDN, Path) ->
    case lists:member(CurrentDN, Path) of
        true  ->
            ?L("recursive cycle on DN ~s while searching for group ~s",
               [CurrentDN, TargetDN]),
            false;
        false ->
            GroupDNs = search_groups(LDAP, Desc, GroupsBase, Scope, CurrentDN),
            case lists:member(TargetDN, GroupDNs) of
                true  ->
                    true;
                false ->
                    NextPath = [CurrentDN | Path],
                    lists:any(fun(DN) ->
                        search_nested_group(LDAP, Desc, GroupsBase, Scope,
                                            DN, TargetDN, NextPath)
                    end,
                    GroupDNs)
            end
    end.

safe_eval(_F, {error, _}, _)          -> false;
safe_eval(_F, _,          {error, _}) -> false;
safe_eval(F,  V1,         V2)         -> F(V1, V2).

do_match(S1, S2) ->
    case re:run(S1, S2) of
        {match, _} -> log_match(S1, S2, R = true),
            R;
        nomatch    -> log_match(S1, S2, R = false),
            R
    end.

do_match_bidirectionally(S1, S2) ->
    case re:run(S1, S2) of
        {match, _} -> log_match(S1, S2, R = true),
                      R;
        nomatch    ->
            %% Do match bidirectionally, if intial RE consists of
            %% multi attributes, else log match and return result.
            case S2 of
                S when length(S) > 1 ->
                    R = case re:run(S2, S1) of
                            {match, _} -> true;
                            nomatch    -> false
                        end,
                    log_match(S2, S1, R),
                    R;
                _ ->
                    log_match(S1, S2, R = false),
                    R
            end
    end.

log_match(String, RE, Result) ->
    ?L1("evaluated match \"~s\" against RE \"~s\": ~s",
        [format_multi_attr(String),
         format_multi_attr(RE), Result]).

object_exists(DN, Filter, LDAP) ->
    case eldap:search(LDAP,
                      [{base, DN},
                       {filter, Filter},
                       {attributes, ["objectClass"]}, %% Reduce verbiage
                       {scope, eldap:baseObject()}]) of
        {ok, #eldap_search_result{entries = Entries}} ->
            length(Entries) > 0;
        {error, _} = E ->
            E
    end.

attribute(DN, AttributeName, LDAP) ->
    case eldap:search(LDAP,
                      [{base, DN},
                       {filter, eldap:present("objectClass")},
                       {attributes, [AttributeName]}]) of
        {ok, #eldap_search_result{entries = E = [#eldap_entry{}|_]}} ->
            get_attributes(AttributeName, E);
        {ok, #eldap_search_result{entries = _}} ->
            {error, not_found};
        {error, _} = E ->
            E
    end.

evaluate_ldap(Q, Args, User) ->
    with_ldap(creds(User), fun(LDAP) -> evaluate(Q, Args, User, LDAP) end).

%%--------------------------------------------------------------------

with_ldap(Creds, Fun) -> with_ldap(Creds, Fun, env(servers)).

with_ldap(_Creds, _Fun, undefined) ->
    {error, no_ldap_servers_defined};

with_ldap({error, _} = E, _Fun, _State) ->
    E;

%% TODO - while we now pool LDAP connections we don't make any attempt
%% to avoid rebinding if the connection is already bound as the user
%% of interest, so this could still be more efficient.
with_ldap({ok, Creds}, Fun, Servers) ->
    Opts0 = [{port, env(port)},
             {idle_timeout, env(idle_timeout)},
             {anon_auth, env(anon_auth)}],
    Opts1 = case env(log) of
                network ->
                    Pre = "    LDAP network traffic: ",
                    rabbit_log:info(
                      "    LDAP connecting to servers: ~p~n", [Servers]),
                    [{log, fun(1, S, A) -> rabbit_log:warning(Pre ++ S, A);
                              (2, S, A) ->
                                   rabbit_log:info(Pre ++ S, scrub_creds(A, []))
                           end} | Opts0];
                network_unsafe ->
                    Pre = "    LDAP network traffic: ",
                    rabbit_log:info(
                      "    LDAP connecting to servers: ~p~n", [Servers]),
                    [{log, fun(1, S, A) -> rabbit_log:warning(Pre ++ S, A);
                              (2, S, A) -> rabbit_log:info(   Pre ++ S, A)
                           end} | Opts0];
                _ ->
                    Opts0
            end,
    %% eldap defaults to 'infinity' but doesn't allow you to set that. Harrumph.
    Opts = case env(timeout) of
               infinity -> Opts1;
               MS       -> [{timeout, MS} | Opts1]
           end,

    worker_pool:submit(
      ldap_pool,
      fun () ->
              case with_login(Creds, Servers, Opts, Fun) of
                  {error, {gen_tcp_error, closed}} ->
                      %% retry with new connection
                      rabbit_log:warning("TCP connection to a LDAP server is already closed.~n"),
                      purge_conn(Creds == anon, Servers, Opts),
                      rabbit_log:warning("LDAP will retry with a new connection.~n"),
                      with_login(Creds, Servers, Opts, Fun);
                  Result -> Result
              end
      end, reuse).

with_login(Creds, Servers, Opts, Fun) ->
    case get_or_create_conn(Creds == anon, Servers, Opts) of
        {ok, LDAP} ->
            case Creds of
                anon ->
                    ?L1("anonymous bind", []),
                    call_ldap_fun(Fun, LDAP);
                {UserDN, Password} ->
                    case eldap:simple_bind(LDAP, UserDN, Password) of
                        ok ->
                            ?L1("bind succeeded: ~s",
                                [scrub_dn(UserDN, env(log))]),
                            call_ldap_fun(Fun, LDAP, UserDN);
                        {error, invalidCredentials} ->
                            ?L1("bind returned \"invalid credentials\": ~s",
                                [scrub_dn(UserDN, env(log))]),
                            {refused, UserDN, []};
                        {error, E} ->
                            ?L1("bind error: ~s ~p",
                                [scrub_dn(UserDN, env(log)), E]),
                            %% Do not report internal bind error to a client
                            {error, ldap_bind_error}
                    end
            end;
        Error ->
            ?L1("connect error: ~p", [Error]),
            case Error of
                {error, {gen_tcp_error, closed}} -> Error;
                %% Do not report internal connection error to a client
                _Other                           -> {error, ldap_connect_error}
            end
    end.

call_ldap_fun(Fun, LDAP) ->
    call_ldap_fun(Fun, LDAP, "").

call_ldap_fun(Fun, LDAP, UserDN) ->
    case Fun(LDAP) of
        {error, E} ->
            ?L1("evaluate error: ~s ~p", [scrub_dn(UserDN, env(log)), E]),
            {error, ldap_evaluate_error};
        Other -> Other
    end.

%% Gets either the anonymous or bound (authenticated) connection
get_or_create_conn(IsAnon, Servers, Opts) ->
    Conns = case get(ldap_conns) of
                undefined -> #{};
                Dict      -> Dict
            end,
    Key = {IsAnon, Servers, Opts},
    case maps:find(Key, Conns) of
        {ok, Conn} ->
            Timeout = rabbit_misc:pget(idle_timeout, Opts, infinity),
            %% Defer the timeout by re-setting it.
            set_connection_timeout(Key, Timeout),
            {ok, Conn};
        error      ->
            {Timeout, EldapOpts} = case lists:keytake(idle_timeout, 1, Opts) of
                false                             -> {infinity, Opts};
                {value, {idle_timeout, T}, EOpts} -> {T, EOpts}
            end,
            case eldap_open(Servers, EldapOpts) of
                {ok, Conn} ->
                    put(ldap_conns, maps:put(Key, Conn, Conns)),
                    set_connection_timeout(Key, Timeout),
                    {ok, Conn};
                Error -> Error
            end
    end.

set_connection_timeout(_, infinity) ->
    ok;
set_connection_timeout(Key, Timeout) when is_integer(Timeout) ->
    worker_pool_worker:set_timeout(Key, Timeout,
        fun() ->
            Conns = case get(ldap_conns) of
                undefined -> #{};
                Dict      -> Dict
            end,
            case maps:find(Key, Conns) of
                {ok, Conn} ->
                    eldap:close(Conn),
                    put(ldap_conns, maps:remove(Key, Conns));
                _ -> ok
            end
        end).

%% Get attribute(s) from eldap entry
get_attributes(_AttrName, []) -> {error, not_found};
get_attributes(AttrName, [#eldap_entry{attributes = A}|Rem]) ->
    case pget(AttrName, A) of
        [Attr|[]]                    -> Attr;
        Attrs when length(Attrs) > 1 -> Attrs;
        _                            -> get_attributes(AttrName, Rem)
    end;
get_attributes(AttrName, [_|Rem])    -> get_attributes(AttrName, Rem).

%% Format multiple attribute values for logging
format_multi_attr(Attrs) ->
    format_multi_attr(io_lib:printable_list(Attrs), Attrs).

format_multi_attr(true, Attrs)                     -> Attrs;
format_multi_attr(_,    Attrs) when is_list(Attrs) -> string:join(Attrs, "; ");
format_multi_attr(_,    Error)                     -> Error.


%% In case of multiple attributes, check for equality bi-directionally
is_multi_attr_member(Str1, Str2) ->
    lists:member(Str1, Str2) orelse lists:member(Str2, Str1).

purge_conn(IsAnon, Servers, Opts) ->
    Conns = get(ldap_conns),
    Key = {IsAnon, Servers, Opts},
    {ok, Conn} = maps:find(Key, Conns),
    rabbit_log:warning("LDAP Purging an already closed LDAP server connection~n"),
    % We cannot close the connection with eldap:close/1 because as of OTP-13327
    % eldap will try to do_unbind first and will fail with a `{gen_tcp_error, closed}`.
    % Since we know that the connection is already closed, we just
    % kill its process.
    unlink(Conn),
    exit(Conn, closed),
    put(ldap_conns, maps:remove(Key, Conns)),
    ok.

eldap_open(Servers, Opts) ->
    case eldap:open(Servers, ssl_conf() ++ Opts) of
        {ok, LDAP} ->
            TLS = env(use_starttls),
            case {TLS, at_least("5.10.4")} of %%R16B03
                {false, _}     -> {ok, LDAP};
                {true,  false} -> exit({starttls_requires_min_r16b3});
                {true,  _}     -> TLSOpts = ssl_options(),
                                  ELDAP = eldap, %% Fool xref
                                  case ELDAP:start_tls(LDAP, TLSOpts) of
                                      ok    -> {ok, LDAP};
                                      Error -> Error
                                  end
            end;
        Error ->
            Error
    end.

ssl_conf() ->
    %% We must make sure not to add SSL options unless a) we have at least R16A
    %% b) we have SSL turned on (or it breaks StartTLS...)
    case env(use_ssl) of
        false -> [{ssl, false}];
        true  -> %% Only the unfixed version can be []
                 case {env(ssl_options), at_least("5.10")} of %% R16A
                     {_,  true}  -> [{ssl, true}, {sslopts, ssl_options()}];
                     {[], _}     -> [{ssl, true}];
                     {_,  false} -> exit({ssl_options_requires_min_r16a})
                 end
    end.

ssl_options() ->
    rabbit_networking:fix_ssl_options(env(ssl_options)).

at_least(Ver) ->
    rabbit_misc:version_compare(erlang:system_info(version), Ver) =/= lt.

env(F) ->
    {ok, V} = application:get_env(rabbitmq_auth_backend_ldap, F),
    V.

login_fun(User, UserDN, Password, AuthProps) ->
    fun(L) -> case pget(vhost, AuthProps) of
                  undefined -> do_login(User, UserDN, Password, L);
                  VHost     -> do_login(User, UserDN, Password, VHost, L)
              end
    end.

do_login(Username, PrebindUserDN, Password, LDAP) ->
    do_login(Username, PrebindUserDN, Password, <<>>, LDAP).

do_login(Username, PrebindUserDN, Password, VHost, LDAP) ->
    UserDN = case PrebindUserDN of
                 unknown -> username_to_dn(Username, LDAP, dn_lookup_when());
                 _       -> PrebindUserDN
             end,
    User = #auth_user{username     = Username,
                      impl         = #impl{user_dn  = UserDN,
                                           password = Password}},
    DTQ = fun (LDAPn) -> do_tag_queries(Username, UserDN, User, VHost, LDAPn) end,
    TagRes = case env(other_bind) of
                 as_user -> DTQ(LDAP);
                 _       -> with_ldap(creds(User), DTQ)
             end,
    case TagRes of
        {ok, L} -> {ok, User#auth_user{tags = [Tag || {Tag, true} <- L]}};
        E       -> E
    end.

do_tag_queries(Username, UserDN, User, VHost, LDAP) ->
    {ok, [begin
              ?L1("CHECK: does ~s have tag ~s?", [Username, Tag]),
              R = evaluate(Q, [{username, Username},
                               {user_dn,  UserDN} | vhost_if_defined(VHost)],
                           User, LDAP),
              ?L1("DECISION: does ~s have tag ~s? ~p",
                  [Username, Tag, R]),
              {Tag, R}
          end || {Tag, Q} <- env(tag_queries)]}.

vhost_if_defined([])    -> [];
vhost_if_defined(<<>>)  -> [];
vhost_if_defined(VHost) -> [{vhost, VHost}].

dn_lookup_when() -> case {env(dn_lookup_attribute), env(dn_lookup_bind)} of
                        {none, _}       -> never;
                        {_,    as_user} -> postbind;
                        {_,    _}       -> prebind
                    end.

username_to_dn_prebind(Username) ->
    with_ldap({ok, env(dn_lookup_bind)},
              fun (LDAP) -> dn_lookup(Username, LDAP) end).

username_to_dn(Username, LDAP,  postbind) -> dn_lookup(Username, LDAP);
username_to_dn(Username, _LDAP, _When)    -> fill_user_dn_pattern(Username).

dn_lookup(Username, LDAP) ->
    Filled = fill_user_dn_pattern(Username),
    case eldap:search(LDAP,
                      [{base, env(dn_lookup_base)},
                       {filter, eldap:equalityMatch(
                                  env(dn_lookup_attribute), Filled)},
                       {attributes, ["distinguishedName"]}]) of
        {ok, #eldap_search_result{entries = [#eldap_entry{object_name = DN}]}}->
            ?L1("DN lookup: ~s -> ~s", [Username, DN]),
            DN;
        {ok, #eldap_search_result{entries = Entries}} ->
            rabbit_log:warning("Searching for DN for ~s, got back ~p~n",
                               [Filled, Entries]),
            Filled;
        {error, _} = E ->
            exit(E)
    end.

fill_user_dn_pattern(Username) ->
    fill(env(user_dn_pattern), [{username, Username}]).

creds(User) -> creds(User, env(other_bind)).

creds(none, as_user) ->
    {error, "'other_bind' set to 'as_user' but no password supplied"};
creds(#auth_user{impl = #impl{user_dn = UserDN, password = PW}}, as_user) ->
    {ok, {UserDN, PW}};
creds(_, Creds) ->
    {ok, Creds}.

%% Scrub credentials
scrub_creds([], Acc)      -> lists:reverse(Acc);
scrub_creds([H|Rem], Acc) ->
    scrub_creds(Rem, [scrub_payload_creds(H)|Acc]).

%% Scrub credentials from specific payloads
scrub_payload_creds({'BindRequest', N, DN, {simple, _PWD}}) ->
  {'BindRequest', N, scrub_dn(DN), {simple, ?SCRUBBED_CREDENTIAL}};
scrub_payload_creds(Any) -> Any.

scrub_dn(DN) -> scrub_dn(DN, network).

scrub_dn(DN, network_unsafe) -> DN;
scrub_dn(DN, false)          -> DN;
scrub_dn(DN, _) ->
    case is_dn(DN) of
        true -> scrub_rdn(string:tokens(DN, ","), []);
        _    ->
            %% We aren't fully certain its a DN, & don't know what sensitive
            %% info could be contained, thus just scrub the entire credential
            ?SCRUBBED_CREDENTIAL
    end.

scrub_rdn([], Acc) ->
    string:join(lists:reverse(Acc), ",");
scrub_rdn([DN|Rem], Acc) ->
    DN0 = case catch string:tokens(DN, "=") of
              L = [RDN, _] -> case string:to_lower(RDN) of
                                  "cn"  -> [RDN, ?SCRUBBED_CREDENTIAL];
                                  "dc"  -> [RDN, ?SCRUBBED_CREDENTIAL];
                                  "ou"  -> [RDN, ?SCRUBBED_CREDENTIAL];
                                  "uid" -> [RDN, ?SCRUBBED_CREDENTIAL];
                                  _     -> L
                              end;
              _Any ->
                  %% There's no RDN, log "xxxx=xxxx"
                  [?SCRUBBED_CREDENTIAL, ?SCRUBBED_CREDENTIAL]
          end,
  scrub_rdn(Rem, [string:join(DN0, "=")|Acc]).

is_dn(S) when is_list(S) ->
    case catch string:tokens(to_list(S), "=") of
        L when length(L) > 1 -> true;
        _                    -> false
    end;
is_dn(_S) -> false.

to_list(S) when is_list(S)   -> S;
to_list(S) when is_binary(S) -> binary_to_list(S);
to_list(S) when is_atom(S)   -> atom_to_list(S);
to_list(S)                   -> {error, {badarg, S}}.

log(Fmt,  Args) -> case env(log) of
                       false -> ok;
                       _     -> rabbit_log:info(Fmt ++ "~n", Args)
                   end.

fill(Fmt, Args) ->
    ?L2("filling template \"~s\" with~n            ~p", [Fmt, Args]),
    R = rabbit_auth_backend_ldap_util:fill(Fmt, Args),
    ?L2("template result: \"~s\"", [R]),
    R.

log_result({ok, #auth_user{}}) -> ok;
log_result(true)               -> ok;
log_result(false)              -> denied;
log_result({refused, _, _})    -> denied;
log_result(E)                  -> E.

log_user(#auth_user{username = U}) -> rabbit_misc:format("\"~s\"", [U]).

log_vhost(Args) ->
    rabbit_misc:format("access to vhost \"~s\"", [pget(vhost, Args)]).

log_resource(Args) ->
    rabbit_misc:format("~s permission for ~s \"~s\" in \"~s\"",
                       [pget(permission, Args), pget(resource, Args),
                        pget(name, Args), pget(vhost, Args)]).
