:- module(pls_index_terms, [
  index_terms/1
  ]).

:- use_module(library(http/json)).
:- use_module(library(log4p)).
:- use_module(library(prolog_stack)).

:- use_module(documents).
:- use_module(docs).
:- use_module(profiles).

% Index the terms in a file, including subterms.
% A file or document is a sequence of terms, and
% terms contains goals.
index_terms(URI) :-
  clear_document_items(URI),
  forall(index_term(URI), true).

%! index_term(+URI) is nondet.
%
% On succesive calls, read and index every time in the source at URI.
%
index_term(URI) :-
  with_content(URI, In, (
    repeat,
    read_term(In, Term, [
      syntax_errors(dec10),
      subterm_positions(SubPos), 
      comments(CommentPos),
      variable_names(Vars)
      ]),
    ( Term \== end_of_file
      -> (
          index_term(URI, SubPos, Term),
          term_position_range(URI, SubPos, Range),
          index_comments(URI, Term, Range, CommentPos),
          index_signature(URI, SubPos, Term, Vars)
          )
      ; (!, fail)
      )
    )).

%! index_term(+URI, +Pos, +Term) is nondet.
%
% Indexing the term at the indicated Position in the
% source with the indicated URI.
%
index_term(URI, Pos, (:- module(Module, Exports))) :-
  term_position_range(URI, Pos, Range),
  add_document_item(URI, Range, module(Module, Exports)),
  % Arg of :-, which is the term position for module
  argument_positions(Pos, [DirectiveArgPos]),
  % Args of module: first is the name, second is export list
  argument_positions(DirectiveArgPos, [_,list_position(_,_,ExportPosList, _)]),
  index_exports(URI, Exports, ExportPosList),
  !.

index_term(URI, Pos, (:- use_module(Module))) :-
  term_position_range(URI, Pos, Range),
  add_document_item(URI, Range, uses(Module)),
  !.

index_term(URI, Pos, (:- reexport(Module))) :-
  term_position_range(URI, Pos, Range),
  add_document_item(URI, Range, reexports(Module)),
  !.

index_term(URI, Pos, (:- reexport(Module, Imports))) :-
  term_position_range(URI, Pos, Range),
  add_document_item(URI, Range, reexports(Module,Imports)),
  !.

index_term(URI, Pos, (:- [FileSpec])) :-
  term_position_range(URI, Pos, Range),
  add_document_item(URI, Range, loads(FileSpec)),
  !.

index_term(URI, Pos, (:- include(FileSpec) )) :-
  term_position_range(URI, Pos, Range),
  add_document_item(URI, Range, includes(FileSpec)),
  !.

index_term(URI, Pos, (_Module:Head :- Body)) :-
  index_term(URI, Pos, (Head :- Body)).

index_term(URI, Pos, (Head :- Body)) :-
  functor(Head, Name, Arity),
  Caller = Name/Arity,
  argument_positions(Pos, [HeadPos, BodyPos]),
  term_position_range(URI, HeadPos, Range),
  add_document_item(URI, Range, defines(Caller)),
  index_goals(URI, Caller, BodyPos, Body),
  !.

index_term(URI, Pos, (Head --> Body)) :-
  functor(Head, Name, Arity),
  Caller = Name//Arity,
  argument_positions(Pos, [HeadPos, BodyPos]),
  term_position_range(URI, HeadPos, Range),
  add_document_item(URI, Range, defines(Caller)),
  index_goals(URI, Caller, BodyPos, Body),
  !.


%! index_comments(+URI, +CommentPos, +TermPos) is nondet.
%
% Index the documentation for the term at the indicated TermPos,
% using the CommentPos from an earlier `read_term/3` call.
%
index_comments(URI, Term, Range, CommentPos) :-
  index_docs(URI, Term, Range, CommentPos),
  !.

index_signature(URI, Pos, Head :- _Body, Vars) :-
  with_output_to(string(Signature),
    write_term(Head,[variable_names(Vars)])
    ),
  term_position_range(URI, Pos, Range),
  functor(Head, Name, Arity),
  add_document_item(URI, Range, signature(Name/Arity, Signature)).

index_signature(_, _, _, _).

%! index_exports(+URI, +Exports, +ExportPosList) is nondet.
%
% Index the exports in a module declaration.
%
index_exports(_URI, [], []).

index_exports(URI, [Export | ExportRest], [ExportPos | ExportPosListRest]) :-
  term_position_range(URI, ExportPos, Range),
  add_document_item(URI, Range, exports(Export)),
  index_exports(URI, ExportRest, ExportPosListRest).

index_goals(URI, Caller, GoalPos, Goal) :-
  forall(index_goal(URI, Caller, GoalPos, Goal), true).

index_goal(URI, Caller, parentheses_term_position(_From, _To, ContentPos), Goal) :-
  index_goal(URI, Caller, ContentPos, Goal).

index_goal(URI, Caller, term_position(_From, _To, FFrom, FTo, _Subpos), Goal) :-
  functor_range(URI, FFrom, FTo, Range),
  ( Caller = _Name // _Arity
    -> ( functor(Goal, Name, Arity), Predicate = Name//Arity) 
    ; ( functor(Goal, Name, Arity), Predicate = Name/Arity)
    ),
  Item = references(Caller, Predicate),
  debug("Adding item %w",[Item]),
  add_document_item(URI, Range, Item) .

index_goal(URI, Caller, term_position(_From, _To, _FFrom, _FTo, Subpos), Goal) :-
  functor(Goal, _Name, Arity),
  between(1, Arity, Index),
  arg(Index, Goal, Arg),
  nth1(Index, Subpos, Pos),
  index_goal(URI, Caller, Pos, Arg).
