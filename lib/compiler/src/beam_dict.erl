%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1998-2024. All Rights Reserved.
%% 
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% 
%% %CopyrightEnd%
%%
%% Purpose: Maintain atom, import, export, and other tables for assembler.

-module(beam_dict).
-moduledoc false.

-export([new/0,opcode/2,highest_opcode/1,
         atom/2,local/4,export/4,import/4,
         string/2,lambda/3,literal/2,line/3,
         fname/2,type/2,debug_info/3,
         atom_table/1,local_table/1,export_table/1,import_table/1,
         string_table/1,lambda_table/1,literal_table/1,
         line_table/1,type_table/1,debug_table/1]).

-include("beam_types.hrl").

-type label() :: beam_asm:label().

-type index() :: non_neg_integer().

-type frame_size() :: 'none' | 'entry' | non_neg_integer().
-type debug_info() :: {frame_size(), list()}.

-type atom_tab()   :: #{atom() => index()}.
-type import_tab() :: gb_trees:tree(mfa(), index()).
-type fname_tab()  :: #{Name :: term() => index()}.
-type line_tab()   :: #{{Fname :: index(), Line :: term()} => index()}.
-type literal_tab() :: #{Literal :: term() => index()}.
-type type_tab()   :: #{Type :: binary() => index()}.
-type debug_tab() :: #{index() => debug_info()}.
-type lambda_info() :: {label(),{index(),label(),non_neg_integer()}}.
-type lambda_tab() :: {non_neg_integer(),[lambda_info()]}.
-type wrapper() :: #{label() => index()}.

-record(asm,
        {atoms = #{}                :: atom_tab(),
         exports = []               :: [{label(), arity(), label()}],
         locals = []                :: [{label(), arity(), label()}],
         imports = gb_trees:empty() :: import_tab(),
         strings = <<>>             :: binary(),    %String pool
         lambdas = {0,[]}           :: lambda_tab(),
         types = #{}                :: type_tab(),
         wrappers = #{}             :: wrapper(),
         literals = #{}	            :: literal_tab(),
         fnames = #{}               :: fname_tab(),
         lines = #{}                :: line_tab(),
         debug = #{}                :: debug_tab(),
         num_lines = 0              :: non_neg_integer(), %Number of line instructions
         exec_line = false          :: boolean(),
         next_import = 0            :: non_neg_integer(),
         string_offset = 0          :: non_neg_integer(),
         next_literal = 0           :: non_neg_integer(),
         highest_opcode = 0         :: non_neg_integer()
        }).

-type bdict() :: #asm{}.

%%-----------------------------------------------------------------------------

-spec new() -> bdict().

new() ->
    #asm{}.

%% Remember the highest opcode.
-spec opcode(non_neg_integer(), bdict()) -> bdict().

opcode(Op, Dict) when Dict#asm.highest_opcode >= Op -> Dict;
opcode(Op, Dict) -> Dict#asm{highest_opcode=Op}.

%% Returns the highest opcode encountered.
-spec highest_opcode(bdict()) -> non_neg_integer().

highest_opcode(#asm{highest_opcode=Op}) -> Op.

%% Returns the index for an atom (adding it to the atom table if necessary).
%%    atom(Atom, Dict) -> {Index,Dict'}
-spec atom(atom(), bdict()) -> {pos_integer(), bdict()}.

atom(Atom, #asm{atoms=Atoms}=Dict) when is_atom(Atom) ->
    case Atoms of
        #{ Atom := Index} -> {Index,Dict};
        _ ->
            NextIndex = maps:size(Atoms) + 1,
            {NextIndex,Dict#asm{atoms=Atoms#{Atom=>NextIndex}}}
    end.

%% Remembers an exported function.
%%    export(Func, Arity, Label, Dict) -> Dict'
-spec export(atom(), arity(), label(), bdict()) -> bdict().

export(Func, Arity, Label, Dict0) when is_atom(Func),
				       is_integer(Arity),
				       is_integer(Label) ->
    {Index, Dict1} = atom(Func, Dict0),
    Dict1#asm{exports = [{Index, Arity, Label}| Dict1#asm.exports]}.

%% Remembers a local function.
%%    local(Func, Arity, Label, Dict) -> Dict'
-spec local(atom(), arity(), label(), bdict()) -> bdict().

local(Func, Arity, Label, Dict0) when is_atom(Func),
				      is_integer(Arity),
				      is_integer(Label) ->
    {Index,Dict1} = atom(Func, Dict0),
    Dict1#asm{locals=[{Index,Arity,Label}|Dict1#asm.locals]}.

%% Returns the index for an import entry (adding it to the import table if necessary).
%%    import(Mod, Func, Arity, Dict) -> {Index,Dict'}
-spec import(atom(), atom(), arity(), bdict()) -> {non_neg_integer(), bdict()}.

import(Mod0, Name0, Arity, #asm{imports=Imp0,next_import=NextIndex}=D0)
  when is_atom(Mod0), is_atom(Name0), is_integer(Arity) ->
    {Mod,D1} = atom(Mod0, D0),
    {Name,D2} = atom(Name0, D1),
    MFA = {Mod,Name,Arity},
    case gb_trees:lookup(MFA, Imp0) of
	{value,Index} ->
	    {Index,D2};
	none ->
	    Imp = gb_trees:insert(MFA, NextIndex, Imp0),
	    {NextIndex,D2#asm{imports=Imp,next_import=NextIndex+1}}
    end.

%% Returns the index for a binary string in the string table (adding
%% the string to the table if necessary).
%%    string(String, Dict) -> {Offset, Dict'}
-spec string(binary(), bdict()) -> {non_neg_integer(), bdict()}.

string(BinString, Dict) when is_binary(BinString) ->
    #asm{strings=Strings,string_offset=NextOffset} = Dict,
    case old_string(BinString, Strings) of
	none ->
	    NewDict = Dict#asm{strings = <<Strings/binary,BinString/binary>>,
			       string_offset=NextOffset+byte_size(BinString)},
	    {NextOffset,NewDict};
	Offset when is_integer(Offset) ->
	    {NextOffset-Offset,Dict}
    end.

%% Returns the index for a fun entry.
%%    lambda(Lbl, NumFree, Dict) -> {Index,Dict'}
-spec lambda(label(), non_neg_integer(), bdict()) ->
        {non_neg_integer(), bdict()}.

lambda(Lbl, NumFree, #asm{wrappers=Wrappers0,
                          lambdas={OldIndex,Lambdas0}}=Dict) ->
    case Wrappers0 of
        #{Lbl:=Index} ->
            %% OTP 23: There old is a fun entry for this wrapper function.
            %% Share the fun entry.
            {Index,Dict};
        #{} ->
            %% Set Index the same as OldIndex.
            Index = OldIndex,
            Wrappers = Wrappers0#{Lbl=>Index},
            Lambdas = [{Lbl,{Index,Lbl,NumFree}}|Lambdas0],
            {OldIndex,Dict#asm{wrappers=Wrappers,
                               lambdas={OldIndex+1,Lambdas}}}
    end.

%% Returns the index for a literal (adding it to the literal table if necessary).
%%    literal(Literal, Dict) -> {Index,Dict'}
-spec literal(term(), bdict()) -> {non_neg_integer(), bdict()}.

-dialyzer({no_improper_lists, literal/2}).

literal(Lit, Dict) when is_float(Lit) ->
    %% A literal 0.0 actually has two representations: 0.0 and -0.0.
    %% While they are equal, they must be encoded differently (the bit sign).
    if
        %% We do not explicitly match on 0.0 because a buggy compiler
        %% could replace Lit by 0.0, which would discard its sign.
        Lit > 0.0; Lit < 0.0 ->
            literal1([term|Lit], Dict);
        true ->
            literal1([binary|my_term_to_binary(Lit)], Dict)
    end;
literal(Lit, Dict) ->
    literal1([term|Lit], Dict).

literal1(Key, #asm{literals=Tab0,next_literal=NextIndex}=Dict) ->
    case Tab0 of
        #{Key:=Index} ->
	    {Index,Dict};
        #{} ->
	    Tab = Tab0#{Key=>NextIndex},
	    {NextIndex,Dict#asm{literals=Tab,next_literal=NextIndex+1}}
    end.

%% Returns the index for a line instruction (adding information
%% to the location information table).
-spec line(list(), bdict(), 'line' | 'executable_line' | 'debug_line') ->
          {non_neg_integer(), bdict()}.

line([], #asm{num_lines=N}=Dict, Instr) when is_atom(Instr) ->
    %% No location available. Return the special pre-defined
    %% index 0.
    {0,Dict#asm{num_lines=N+1}};
line([{location,Name,Line}|_], #asm{lines=Lines,num_lines=N,
                                    exec_line=ExecLine0}=Dict0, Instr)
  when is_atom(Instr) ->
    {FnameIndex,Dict1} = fname(Name, Dict0),
    Key = {FnameIndex,Line},
    ExecLine = ExecLine0 or (Instr =:= executable_line),
    case Lines of
        #{Key := Index} ->
            {Index,Dict1#asm{num_lines=N+1,exec_line=ExecLine}};
        _ ->
            Index = map_size(Lines) + 1,
            {Index, Dict1#asm{lines=Lines#{Key=>Index},num_lines=N+1,
                              exec_line=ExecLine}}
    end;
line([_|T], #asm{}=Dict, Instr) ->
    line(T, Dict, Instr).

-spec fname(nonempty_string(), bdict()) ->
                   {non_neg_integer(), bdict()}.

fname(Name, #asm{fnames=Fnames}=Dict) ->
    case Fnames of
        #{Name := Index} -> {Index,Dict};
        _ ->
            Index = maps:size(Fnames),
	    {Index,Dict#asm{fnames=Fnames#{Name=>Index}}}
    end.

-spec type(type(), bdict()) -> {non_neg_integer(), bdict()} | none.

type(Type, #asm{types=Types0}=Dict) ->
    ExtType = beam_types:encode_ext(Type),
    case Types0 of
        #{ ExtType := Index } ->
            {Index, Dict};
        #{} ->
            Index = map_size(Types0),
            Types = Types0#{ ExtType => Index },
            {Index, Dict#asm{types=Types}}
    end.

-spec debug_info(index(), debug_info(), bdict()) -> bdict().

debug_info(Index, DebugInfo, #asm{debug=DebugTab0}=Dict)
  when is_integer(Index) ->
    false = is_map_key(Index, DebugTab0),       %Assertion.
    DebugTab = DebugTab0#{Index => DebugInfo},
    Dict#asm{debug=DebugTab}.

%% Returns the atom table.
%%    atom_table(Dict, Encoding) -> {LastIndex,[Length,AtomString...]}
-spec atom_table(bdict()) -> {non_neg_integer(), [[non_neg_integer(),...]]}.

atom_table(#asm{atoms=Atoms}) ->
    NumAtoms = maps:size(Atoms),
    Sorted = lists:keysort(2, maps:to_list(Atoms)),
    {NumAtoms,[begin
                   L = atom_to_binary(A, utf8),
                   [byte_size(L),L]
               end || {A,_} <:- Sorted]}.

%% Returns the table of local functions.
%%    local_table(Dict) -> {NumLocals, [{Function, Arity, Label}...]}
-spec local_table(bdict()) -> {non_neg_integer(), [{index(),arity(),label()}]}.

local_table(#asm{locals = Locals}) ->
    {length(Locals),Locals}.

%% Returns the export table.
%%    export_table(Dict) -> {NumExports, [{Function, Arity, Label}...]}
-spec export_table(bdict()) -> {non_neg_integer(), [{index(),arity(),label()}]}.

export_table(#asm{exports = Exports}) ->
    {length(Exports),Exports}.

%% Returns the import table.
%%    import_table(Dict) -> {NumImports, [{Module, Function, Arity}...]}
-spec import_table(bdict()) -> {non_neg_integer(), [{label(),label(),arity()}]}.

import_table(#asm{imports=Imp,next_import=NumImports}) ->
    Sorted = lists:keysort(2, gb_trees:to_list(Imp)),
    ImpTab = [MFA || {MFA,_} <:- Sorted],
    {NumImports,ImpTab}.

-spec string_table(bdict()) -> {non_neg_integer(), binary()}.

string_table(#asm{strings=Strings,string_offset=Size}) ->
    {Size,Strings}.

-spec lambda_table(bdict()) -> {non_neg_integer(), [<<_:192>>]}.

lambda_table(#asm{locals=Loc0,exports=Ext0,lambdas={NumLambdas,Lambdas0}}) ->
    Lambdas1 = sofs:relation(Lambdas0),
    Loc = sofs:relation([{Lbl,{F,A}} || {F,A,Lbl} <:- Loc0]),
    Ext = sofs:relation([{Lbl,{F,A}} || {F,A,Lbl} <:- Ext0]),
    All = sofs:union(Loc, Ext),
    Lambdas2 = sofs:relative_product1(Lambdas1, All),
    %% Initialize OldUniq to 0. It will be set to an unique value
    %% based on the MD5 checksum of the BEAM code for the module.
    OldUniq = 0,
    Lambdas = [<<F:32,A:32,Lbl:32,Index:32,NumFree:32,OldUniq:32>> ||
                  {{Index,Lbl,NumFree},{F,A}} <:- sofs:to_external(Lambdas2)],
    {NumLambdas,Lambdas}.

%% Returns the literal table.
%%    literal_table(Dict) -> {NumLiterals, [<<TermSize>>,TermInExternalFormat]}
-spec literal_table(bdict()) -> {non_neg_integer(), [[binary(),...]]}.

literal_table(#asm{literals=Tab,next_literal=NumLiterals}) ->
    L0 = maps:fold(fun
			([term|Lit], Num, Acc) ->
			   [{Num,my_term_to_binary(Lit)}|Acc];
			([binary|Lit], Num, Acc) ->
			   [{Num,Lit}|Acc]
		   end, [], Tab),
    L1 = lists:sort(L0),
    L = [[<<(byte_size(Term)):32>>,Term] || {_,Term} <:- L1],
    {NumLiterals,L}.

my_term_to_binary(Term) ->
    %% Use the latest possible minor version. Minor version 2 can be
    %% be decoded by OTP 16, which is as far back as we have compatibility
    %% options for the compiler. (When this comment was written, some time
    %% after the release of OTP 22, the default minor version was 1.)

    term_to_binary(Term, [{minor_version,2},deterministic]).

%% Returns the type table.
-spec type_table(bdict()) -> {non_neg_integer(), binary()}.

type_table(#asm{types=Types}) ->
    Sorted = lists:keysort(2, maps:to_list(Types)),
    {map_size(Types), build_type_table(Sorted, <<>>)}.

build_type_table([{ExtType, _} | Sorted], Acc) ->
    build_type_table(Sorted, <<Acc/binary, ExtType/binary>>);
build_type_table([], Acc) ->
    Acc.

%% Return the line table.
-spec line_table(bdict()) ->
    {non_neg_integer(),				%Number of line instructions.
     non_neg_integer(),[string()],
     non_neg_integer(),[{non_neg_integer(),non_neg_integer()}],
     boolean()}.

line_table(#asm{fnames=Fnames0,lines=Lines0,
                num_lines=NumLineInstrs,exec_line=ExecLine}) ->
    NumFnames = maps:size(Fnames0),
    Fnames1 = lists:keysort(2, maps:to_list(Fnames0)),
    Fnames = [Name || {Name,_} <:- Fnames1],
    NumLines = maps:size(Lines0),
    Lines1 = lists:keysort(2, maps:to_list(Lines0)),
    Lines = [L || {L,_} <:- Lines1],
    {NumLineInstrs,NumFnames,Fnames,NumLines,Lines,ExecLine}.


-spec debug_table(bdict()) -> debug_tab().

debug_table(#asm{debug=Debug}) ->
    Debug.

%% Search for binary string Str in the binary string pool Pool.
%%    old_string(Str, Pool) -> none | Index
-spec old_string(binary(), binary()) -> 'none' | pos_integer().

old_string(Str, Pool) ->
    case binary:match(Pool, Str) of
        nomatch -> none;
        {Start,_Length} -> byte_size(Pool) - Start
    end.
