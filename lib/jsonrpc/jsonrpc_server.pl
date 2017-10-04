:- module(jsonrpc_server,[
  start_jsonrpc_server/2,
  stop_jsonrpc_server/2,

  method/3,
  echo/2

]).

:- use_module(library(http/json)).
:- use_module(library(http/json_convert)).
:- use_module(library(socket)).

:- use_module(library(log4p)).
:- use_module(library(jsonrpc/jsonrpc_server)).

:- meta_predicate
  method(:,:,?),
  declared_method(?,:,?),
  declared_method(?,?,:).

:- dynamic jsonrpc_connection/4.

start_jsonrpc_server(Server,Port) :-
  \+recorded(jsonrpc_server(Server,Port),_,_),
  thread_create(safe_run_server(Server,Port),ServerThreadId,[]),
  recorda(jsonrpc_server(Server,Port),ServerThreadId).

stop_jsonrpc_server(Server,Port) :-
  recorded(jsonrpc_server(Server,Port),ServerThreadId,Reference),
  thread_signal(ServerThreadId,throw(exit)),
  thread_join(ServerThreadId,Status),
  info('JSON RPC server %s exited with %t',[Server,Status]),
  erase(Reference).

safe_run_server(Server,Port) :-
  info('Started JSON RPC server %w on %w',[Server,Port]),
  catch(
    setup_call_cleanup(
      setup_server(Port,Socket),
      run_server(Server,Port,Socket),
      cleanup_server(Server,Port,Socket)
      ),
    Exception,
    warn('Exited JSON RPC server %w: %w',[Server,Exception])).

setup_server(Port,Socket) :-
  tcp_socket(Socket),
  tcp_bind(Socket, Port).

run_server(Server,Port,Socket) :-
  tcp_listen(Socket, 5),
  tcp_open_socket(Socket, AcceptFd, _),
  dispatch_connections(Server,Port,AcceptFd).

cleanup_server(Server,Port,Socket) :-
  catch(
    tcp_close_socket(Socket),
    _,
    info('Stopped JSON RPC server %w on %w',[Server,Port])),
  findall(ConnectionThreadId,jsonrpc_connection(Server,Port,_,ConnectionThreadId),ConnectionThreadIds),
  forall(member(ThreadId,ConnectionThreadIds),thread_signal(ThreadId,throw(exit))).

dispatch_connections(Server,Port,ServerFd) :-
  tcp_accept(ServerFd, Client, Peer),
  thread_create(safe_handle_connection(Server,Port,Client, Peer), _,
                [ detached(true),
                  debug(false)
                ]),
  dispatch_connections(Server,Port,ServerFd).

safe_handle_connection(Server, Port, Socket, Peer) :-
  setup_call_cleanup(
    setup_connection(Server, Port, Socket, Peer, StreamPair),
    catch(
      handle_connection(Server, Peer, StreamPair),
      exit,
      info('Exiting connection from %w to %w on %w',[Peer,Server,Port])),
    cleanup_connection(Server, Port, Peer, StreamPair)).

setup_connection(Server, Port, Socket, Peer, StreamPair) :-
  % Note there is still a chance of races, but this hopefully helps with cleanup of connections
  thread_self(ThreadId),
  \+ jsonrpc_connection(Server, Port, Peer,ThreadId),
  asserta(jsonrpc_connection(Server, Port, Peer,ThreadId)),
  tcp_open_socket(Socket, StreamPair).

handle_connection(Server, Peer,StreamPair) :-
  stream_pair(StreamPair,In,Out),
  read_message(In,Message),
  handle_message(Server, Peer,Out,Message),
  handle_connection(Server, Peer,StreamPair).

handle_message(Server, Peer,Out,Message) :-
  is_list(Message)
    -> handle_batch(Server, Peer, Out, Message)
    ; handle_notification_or_request(Server, Peer, Out, Message).

handle_batch(Server, Peer,Out,[Message|Rest]) :-
  handle_notification_or_request(Server, Peer, Out, Message),
  handle_batch(Server, Peer, Out, Rest).

handle_batch(_, _, _ , []).

handle_notification_or_request(Server, Peer, Out, Message) :-
  Message.get(id) = _Id
    -> handle_request(Server, Peer,Out,Message)
    ; handle_notification(Server, Peer,Out,Message).

handle_notification(Server, _Peer, _Out, Request) :-
  dispatch_method(Server, Request.id, Request.method, Request.params, _Result).

handle_request(Server, _Peer, Out, Request) :-
  catch(
      dispatch_method(Server, Request.id, Request.method, Request.params, Response),
      Exception,
      dispatch_exception(Server,Request.id,Exception,Response)),
  write_response(Out,Response).

cleanup_connection(Server, Port, Peer, StreamPair) :-
  close(StreamPair),
  thread_self(ThreadId),
  retractall(jsonrpc_connection(Server, Port, Peer, ThreadId)),
  info('Closed connection to %w',[Peer]).

read_message(In,Request) :-
    json_read_dict(In,Request).

write_response(Out,Response) :-
  json_write(Out,Response),
  write(Out,'\n'),
  flush_output(Out).

:- dynamic declared_method/3.

method(Server, Method, Module:Handler) :-
  Clause = declared_method(Server, Method, Module:Handler),
  ( Clause ; asserta(Clause) ).

dispatch_method(Server, Id, MethodName, Params, Response) :-
  atom_string(Method,MethodName),
  (declared_method(_MServer:Server, _MMethod:Method, Module:Handler) ;
    throw(unknown_method(Method))),
  apply(Module:Handler,[Result,Params]),
  Response = _{id: Id, result: Result }.

:- dynamic declared_exception/3.

dispatch_exception(Server, Id, Exception, Response) :-
  declared_exception(Server, Exception, Module:Handler),!,
  apply(Module:Handler, [Server, Exception, Error]),
  Response = _{id: Id, error: Error}.

% simple method to echo parameters; good for testing
echo(Params,Params) :-
  info('Echoing %w', [Params]).

declared_exception(_,unknown_method(_),jsonrpc_server:unknown_method).

declared_exception(_,_,jsonrpc_server:unknown_error).

unknown_method(_Server, unknown_method(Method),Error) :-
  swritef(Message, "Unknown method: %w",[Method]),
  Error = _{code: -32601, message: Message },!.

unknown_error(_Server, Exception, Error) :-
  error("An unknown error occurred: %t", [Exception]),
  Error = _{code: -32000, message: "An unknown error occurred" }, !.
