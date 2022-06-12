async-eio-lwt-chimera is an OCaml application that uses three different concurrency libraries (Async, Eio and Lwt).
It is a proof-of-concept that demonstrates how they can all be used together.

The test application:

- Runs an Async server that handles connections using an Lwt handler that reads a line from the request
  and then handles it by using Eio to read the named file from its data directory.

- Runs an Eio client that tries using it.

This README.md file can be executed with ocaml-mdx to test the code:

```
git clone --recursive https://github.com/talex5/async-eio-lwt-chimera.git
cd async-eio-lwt-chimera
opam pin -yn async_eio.dev ./async_eio
opam pin -yn lwt_eio.dev ./lwt_eio
opam install async_eio lwt_eio mdx eio_main
dune runtest
```

## Imports

We'll be using libraries from all three concurrency frameworks:

```ocaml
# #require "eio_main";;
# #require "async_eio";;
# #require "lwt_eio";;
# open Eio.Std;;
```

## The Lwt connection handler

This Lwt code reads one line from the connection, looks it up using a configurable lookup function,
and writes out the reply.

```ocaml
module Lwt_handler = struct
  open Lwt.Syntax

  type t = {
    lookup : string -> string Lwt.t;
  }

  let create lookup = { lookup }

  let handle_client t ~r ~w =
    let* request = Lwt_io.read_line r in
    let* reply = t.lookup request in
    Lwt_io.write_from_string_exactly w reply 0 (String.length reply)
end
```

## The Async server

For the web-server, we'll use Async's TCP module. The server takes an Async connection handler function:

```ocaml
module Server = struct
  open Async_kernel
  open Async_unix

  type handler = r:Reader.t -> w:Writer.t -> unit Deferred.t

  let run ~port (handler : handler) =
    Tcp.Server.create
      ~on_handler_error:`Raise
      (Tcp.Where_to_listen.of_port port)
      (fun _addr r w ->
         handler ~r ~w >>= fun () ->
         Writer.flushed w
      )

  let close = Tcp.Server.close
end
```

## Adapting the Lwt code

First, here are some handy conversions between `Lwt_io` and `Eio.Flow` types:

```ocaml
let lwt_input_of_source src =
  Lwt_io.(make ~mode:input) (fun buf off len ->
     let buf = Cstruct.of_bigarray buf ~off ~len in
     Lwt_eio.run_eio (fun () -> Eio.Flow.read src buf)
  )

let lwt_output_of_sink sink =
  Lwt_io.(make ~mode:output) (fun buf off len ->
     Lwt_eio.run_eio (fun () ->
        let src = Eio.Flow.cstruct_source [Cstruct.of_bigarray buf ~off ~len] in
        Eio.Flow.copy src sink;
        len
     )
  )
```

We can wrap the Lwt `handle_client` function to provide an Eio API:

```ocaml
# let handle_client t ~r ~w =
    let r = lwt_input_of_source r in
    let w = lwt_output_of_sink w in
    Lwt_eio.Promise.await_lwt (Lwt_handler.handle_client t ~r ~w);;
val handle_client :
  Lwt_handler.t -> r:#Eio.Flow.source -> w:#Eio.Flow.sink -> unit = <fun>
```

And then wrap it again to provide an Async API:

```ocaml
# let handle_client t ~r ~w =
    Async_eio.run_eio (fun () ->
       handle_client t
         ~r:(Async_eio.Flow.source_of_reader r)
         ~w:(Async_eio.Flow.sink_of_writer w)
    );;
val handle_client :
  Lwt_handler.t ->
  r:Async_unix.Reader.t ->
  w:Async_unix.Writer.t -> unit Async_kernel.Deferred.t = <fun>
```

## The Eio lookup function

This loads the file named `request` from the directory `data`:

```ocaml
let lookup ~data request =
  try Eio.Dir.load data request
  with Eio.Dir.Not_found _ -> "404 Not Found"
```

## A test client

We'll use Eio for the test client. It connects to the server, sends the request, and then returns the reply:

```ocaml
let run_client ~net ~port request =
  Switch.run @@ fun sw ->
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw net addr in
  Eio.Flow.copy_string (request ^ "\n") flow;
  Eio.Flow.shutdown flow `Send;
  Eio.Buf_read.(parse_exn take_all) flow ~max_size:max_int
```

## The main function

The main function takes a network and a directory to serve,
starts the server running, using the Lwt connection handler configured with the Eio lookup function,
and tries fetching `README.txt` using the client:

```ocaml
let port = 8080

let main ~net ~data =
  let lookup = Lwt_handler.create (fun request ->
     Lwt_eio.run_eio (fun () -> lookup ~data request)
  ) in
  let handler = handle_client lookup in
  let server = Async_eio.run_async (fun () -> Server.run ~port:8080 handler) in
  let reply = run_client ~net ~port "README.txt" in
  traceln "Client received: %S" reply;
  Async_eio.run_async (fun () -> Server.close server)
```

To test it, we need to create some test data:

```sh
$ mkdir srv
$ echo 'It works!' > srv/README.txt
```

Finally, we set up the three event loops and call `main`:

```ocaml
# Eio_main.run @@ fun env ->
  let net = env#net in
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
  Async_eio.with_event_loop @@ fun _ ->
  Eio.Dir.with_open_dir env#cwd "srv" @@ fun data ->
  main ~net ~data;;;
+Client received: "It works!\n"
- : unit = ()
```
