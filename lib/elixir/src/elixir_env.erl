-module(elixir_env).
-include("elixir.hrl").
-export([
  new/0, to_caller/1, with_vars/2, reset_vars/1, env_to_ex/1, env_to_ex/2,
  reset_unused_vars/1, check_unused_vars/2, merge_and_check_unused_vars/3,
  trace/2, format_error/1,
  reset_read/2, prepare_write/1, close_write/2
]).

new() ->
  #{
    '__struct__' => 'Elixir.Macro.Env',
    module => nil,                                    %% the current module
    file => <<"nofile">>,                             %% the current filename
    line => 1,                                        %% the current line
    function => nil,                                  %% the current function
    context => nil,                                   %% can be match, guard or nil
    aliases => [],                                    %% a list of aliases by new -> old names
    requires => elixir_dispatch:default_requires(),   %% a set with modules required
    functions => elixir_dispatch:default_functions(), %% a list with functions imported from module
    macros => elixir_dispatch:default_macros(),       %% a list with macros imported from module
    macro_aliases => [],                              %% keep aliases defined inside a macro
    context_modules => [],                            %% modules defined in the current context
    versioned_vars => #{},                            %% a map of vars with their latest versions
    lexical_tracker => nil,                           %% lexical tracker PID
    tracers => []                                     %% available compilation tracers
  }.

trace(Event, #{tracers := Tracers} = E) ->
  [ok = Tracer:trace(Event, E) || Tracer <- Tracers],
  ok.

to_caller({Line, #elixir_ex{vars={Read, _}}, Env}) ->
  Env#{line := Line, versioned_vars := Read};
to_caller(#{} = Env) ->
  Env.

with_vars(Env, Vars) when is_list(Vars) ->
  {ReversedVars, _} =
    lists:foldl(fun(Var, {Acc, I}) -> {[{Var, I} | Acc], I + 1} end, {[], 0}, Vars),
  Env#{versioned_vars := maps:from_list(ReversedVars)};
with_vars(Env, #{} = Vars) ->
  Env#{versioned_vars := Vars}.

reset_vars(Env) ->
  Env#{versioned_vars := #{}}.

%% CONVERSIONS

env_to_ex(Env) ->
  env_to_ex(Env, false).

env_to_ex(#{context := match, versioned_vars := Vars}, Prune) ->
  Counter = map_size(Vars),
  Unused = unused(Vars, Prune),
  #elixir_ex{prematch={Vars, Counter}, vars={Vars, false}, unused={Unused, Counter}};
env_to_ex(#{versioned_vars := Vars}, Prune) ->
  Unused = unused(Vars, Prune),
  #elixir_ex{vars={Vars, false}, unused={Unused, map_size(Vars)}}.

unused(_Vars, false) -> #{};
unused(Vars, true) -> maps:from_list([{K, {0, false}} || K <- maps:to_list(Vars)]).

%% VAR HANDLING

reset_read(#elixir_ex{vars={_, Write}} = S, #elixir_ex{vars={Read, _}}) ->
  S#elixir_ex{vars={Read, Write}}.

prepare_write(#elixir_ex{vars={Read, _}} = S) ->
  S#elixir_ex{vars={Read, Read}}.

close_write(#elixir_ex{vars={_Read, Write}} = S, #elixir_ex{vars={_, false}}) ->
  S#elixir_ex{vars={Write, false}};
close_write(#elixir_ex{vars={_Read, Write}} = S, #elixir_ex{vars={_, UpperWrite}}) ->
  S#elixir_ex{vars={Write, merge_vars(UpperWrite, Write)}}.

merge_vars(V, V) ->
  V;
merge_vars(V1, V2) ->
  maps:fold(fun(K, M2, Acc) ->
    case Acc of
      #{K := M1} when M1 >= M2 -> Acc;
      _ -> Acc#{K => M2}
    end
  end, V1, V2).

%% UNUSED VARS

reset_unused_vars(#elixir_ex{unused={_Unused, Version}} = S) ->
  S#elixir_ex{unused={#{}, Version}}.

check_unused_vars(#elixir_ex{unused={Unused, _Version}}, E) ->
  [elixir_errors:form_warn([{line, Line}], E, ?MODULE, {unused_var, Name, Overridden}) ||
    {{{Name, nil}, _}, {Line, Overridden}} <- maps:to_list(Unused), is_unused_var(Name)],
  E.

merge_and_check_unused_vars(S, #elixir_ex{vars={Read, Write}, unused={Unused, _Version}}, E) ->
  #elixir_ex{unused={ClauseUnused, Version}} = S,
  NewUnused = merge_and_check_unused_vars(Read, Unused, ClauseUnused, E),
  S#elixir_ex{unused={NewUnused, Version}, vars={Read, Write}}.

merge_and_check_unused_vars(Current, Unused, ClauseUnused, E) ->
  maps:fold(fun
    ({Var, Count} = Key, false, Acc) ->
      case Current of
        #{Var := CurrentCount} when Count =< CurrentCount ->
          %% The parent knows it, so we have to propagate it was used up.
          Acc#{Key => false};

        #{} ->
          Acc
      end;

    ({{Name, Kind}, _Count}, {Line, Overridden}, Acc) ->
      case (Kind == nil) andalso is_unused_var(Name) of
        true ->
          Warn = {unused_var, Name, Overridden},
          elixir_errors:form_warn([{line, Line}], E, ?MODULE, Warn);

        false ->
          ok
      end,

      Acc
  end, Unused, ClauseUnused).

is_unused_var(Name) ->
  case atom_to_list(Name) of
    "_" ++ Rest -> is_compiler_var(Rest);
    _ -> true
  end.

is_compiler_var([$_]) -> true;
is_compiler_var([Var | Rest]) when Var =:= $_; Var >= $A, Var =< $Z -> is_compiler_var(Rest);
is_compiler_var(_) -> false.

format_error({unused_var, Name, Overridden}) ->
  case atom_to_list(Name) of
    "_" ++ _ ->
      io_lib:format("unknown compiler variable \"~ts\" (expected one of __MODULE__, __ENV__, __DIR__, __CALLER__, __STACKTRACE__)", [Name]);
    _ when Overridden ->
      io_lib:format("variable \"~ts\" is unused (there is a variable with the same name in the context, use the pin operator (^) to match on it or prefix this variable with underscore if it is not meant to be used)", [Name]);
    _ ->
      io_lib:format("variable \"~ts\" is unused (if the variable is not meant to be used, prefix it with an underscore)", [Name])
  end.
