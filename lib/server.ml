(*----------------------------------------------------------------------------
 * Copyright (c) 2020-2022, António Nuno Monteiro
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from
 *    this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *---------------------------------------------------------------------------*)

open Import
include Server_intf
module Logs = (val Logging.setup ~src:"piaf.server" ~doc:"Piaf Server module")
module Reqd = Httpun.Reqd
module Server_connection = Httpun.Server_connection
module Config = Server_config

type 'ctx ctx = 'ctx Handler.ctx =
  { ctx : 'ctx
  ; request : Request.t
  }

let default_error_handler : Server_intf.error_handler =
 fun _client_addr ?request:_ ~respond (_error : Error.server) ->
  respond ~headers:(Headers.of_list [ "connection", "close" ]) Body.empty

type t =
  { config : Config.t
  ; error_handler : error_handler
  ; handler : Request_info.t Handler.t
  }

let create ?(error_handler = default_error_handler) ~config handler : t =
  { config; error_handler; handler }

let is_requesting_h2c_upgrade ~config ~version ~scheme headers =
  match
    config.Config.h2c_upgrade, version, config.Config.max_http_version, scheme
  with
  | true, Versions.HTTP.HTTP_1_1, HTTP_2, `HTTP ->
    (match
       Headers.(
         get headers Well_known.connection, get headers Well_known.upgrade)
     with
    | Some connection, Some "h2c" ->
      let connection_segments = String.split_on_char ',' connection in
      List.exists
        (fun segment ->
           let normalized = segment |> String.lowercase_ascii |> String.trim in
           String.equal Headers.Well_known.upgrade normalized)
        connection_segments
    | _ -> false)
  | _ -> false

let do_h2c_upgrade ~sw ~fd ~request_body server =
  let upgrade_handler =
    let { config; error_handler; handler } = server in
    fun ~sw:_ client_address (request : Request.t) upgrade ->
      let http_request =
        Httpun.Request.create
          ~headers:
            (Httpun.Headers.of_rev_list (Headers.to_rev_list request.headers))
          request.meth
          request.target
      in
      let connection =
        Result.get_ok
          (Http2.HTTP.Server.create_h2c_connection_handler
             ~config
             ~sw
             ~fd
             ~error_handler
             ~http_request
             ~request_body
             ~client_address
             handler)
      in
      upgrade (Gluten.make (module H2.Server_connection) connection)
  in
  fun { request; ctx = { Request_info.client_address; _ } } ->
    let headers =
      Headers.(
        of_list [ Well_known.connection, "Upgrade"; Well_known.upgrade, "h2c" ])
    in
    Response.Upgrade.generic ~headers (upgrade_handler client_address request)

let http_connection_handler t : connection_handler =
  let (module Http) =
    match t.config.max_http_version, t.config.h2c_upgrade with
    | HTTP_2, true | (HTTP_1_0 | HTTP_1_1), _ ->
      (module Http1.HTTP : Http_intf.HTTP)
    | HTTP_2, false -> (module Http2.HTTP : Http_intf.HTTP)
  in
  fun ~sw socket client_address ->
    let { error_handler; handler; config } = t in
    let request_handler ctx =
      let { request = { version; headers; body; _ }
          ; ctx = { Request_info.scheme; _ }
          }
        =
        ctx
      in
      match is_requesting_h2c_upgrade ~config ~version ~scheme headers with
      | false -> handler ctx
      | true ->
        let h2c_handler =
          let request_body = Body.to_list body in
          do_h2c_upgrade ~sw ~fd:socket ~request_body t
        in
        h2c_handler ctx
    in
    Http.Server.create_connection_handler
      ~config
      ~error_handler
      ~request_handler
      ~sw
      socket
      client_address

let https_connection_handler ~https ~clock t : connection_handler =
  let { error_handler; handler; config } = t in
  fun ~sw socket client_address ->
    match
      Openssl.accept
        ~clock
        ~config:https
        ~max_http_version:config.max_http_version
        ~timeout:config.accept_timeout
        socket
    with
    | Error (`Exn exn) ->
      Format.eprintf "Accept EXN: %s@." (Printexc.to_string exn)
    | Error (`Connect_error string) ->
      Format.eprintf "CONNECT ERROR: %s@." string
    | Ok { Openssl.socket = ssl_server; alpn_version } ->
      let (module Https) =
        match alpn_version with
        | HTTP_1_0 | HTTP_1_1 -> (module Http1.HTTPS : Http_intf.HTTPS)
        | HTTP_2 ->
          (* TODO: What if `config.max_http_version` is HTTP/1.1? *)
          (module Http2.HTTPS : Http_intf.HTTPS)
      in

      Https.Server.create_connection_handler
        ~config
        ~error_handler
        ~request_handler:handler
        ~sw
        ssl_server
        client_address

module Command = struct
  exception Server_shutdown

  type connection_handler = Server_intf.connection_handler

  module Shutdown_resolver = struct
    type t = unit -> unit

    let empty = Fun.id, Hashtbl.create 0
  end

  type nonrec t =
    { (* types like [_ array] mean per domain * listening address *)
      sockets :
        Eio_unix.Net.listening_socket_ty Eio_unix.Net.listening_socket list
    ; shutdown_resolvers : Shutdown_resolver.t array
    ; client_sockets :
        ( int
          , Eio_unix.Net.stream_socket_ty Eio_unix.Net.stream_socket )
          Hashtbl.t
          array
    ; clock : float Eio.Time.clock_ty r
    ; shutdown_timeout : float
    }

  let shutdown =
    let length sockets =
      Array.fold_left (fun acc item -> Hashtbl.length item + acc) 0 sockets
    in
    fun { sockets; shutdown_resolvers; client_sockets; clock; shutdown_timeout } ->
      Logs.info (fun m -> m "Starting server teardown...");
      Array.iter (fun resolver -> resolver ()) shutdown_resolvers;
      (* Close the server sockets to stop accepting new connections *)
      List.iter Eio.Net.close sockets;
      (* Wait for [shutdown_timeout] seconds before shutting down client
         sockets *)
      Fiber.first
        (fun () ->
           (* We can exit earlier, without waiting for the full timeout. Check
              every 100 ms. *)
           while length client_sockets > 0 do
             Eio.Time.sleep clock 0.1
           done)
        (* TODO(anmonteiro): we can be a whole lot smarter, and start sending
           `connection: close` in headers as soon as we detect we're shutting
           down. *)
        (fun () ->
           Eio.Time.sleep clock shutdown_timeout;
           (* Shut down all client sockets after the shutdown timeout has
              elapsed. *)
           Array.iter
             (fun client_sockets ->
                Hashtbl.iter
                  (fun _ client_socket ->
                     try Eio.Flow.shutdown client_socket `All with
                     | Eio.Io
                         (Eio.Exn.X (Eio_unix.Unix_error (ENOTCONN, _, _)), _)
                       ->
                       Logs.debug (fun m -> m "Socket already disconnected"))
                  client_sockets)
             client_sockets);
      Logs.info (fun m -> m "Server teardown finished")

  let listen =
    let accept_loop ~sw ~listening_socket ~client_sockets connection_handler =
      let accept =
        let id = ref 0 in
        let rec accept () =
          Eio.Net.accept_fork
            listening_socket
            ~sw
            ~on_error:(fun exn ->
              let bt = Printexc.get_backtrace () in
              Logs.err (fun m ->
                m
                  "Error in connection handler: %s@\n%s"
                  (Printexc.to_string exn)
                  bt))
            (fun socket addr ->
               Switch.run (fun sw ->
                 let connection_id =
                   let cid = !id in
                   incr id;
                   cid
                 in
                 Hashtbl.replace client_sockets connection_id socket;
                 Switch.on_release sw (fun () ->
                   Hashtbl.remove client_sockets connection_id);
                 connection_handler ~sw socket addr));
          accept ()
        in
        accept
      in
      let released_p, released_u = Promise.create () in
      Fiber.fork ~sw (fun () ->
        Fiber.first (fun () -> Promise.await released_p) accept);
      fun () -> Promise.resolve released_u ()
    in
    fun ~sw
      ~address
      ~backlog
      ~reuse_addr
      ~reuse_port
      ~domains
      ~shutdown_timeout
      env
      connection_handler ->
      let listening_socket =
        let network = Eio.Stdenv.net env in
        Eio.Net.listen ~reuse_addr ~reuse_port ~backlog ~sw network address
      in
      let resolvers = Array.make domains Shutdown_resolver.empty in
      let started_domains = Eio.Semaphore.make domains in
      let run_accept_loop =
        let resolver_mutex = Eio.Mutex.create () in
        fun idx ->
          Switch.run (fun sw ->
            let resolver =
              let client_sockets = Hashtbl.create 256 in
              let resolver =
                accept_loop
                  ~sw
                  ~client_sockets
                  ~listening_socket
                  connection_handler
              in
              resolver, client_sockets
            in
            Eio.Mutex.lock resolver_mutex;
            resolvers.(idx) <- resolver;
            Eio.Mutex.unlock resolver_mutex;
            Eio.Semaphore.acquire started_domains)
      in
      for idx = 0 to domains - 1 do
        let run_accept_loop () = run_accept_loop idx in
        if idx = domains - 1
        then
          (* Last domain starts on the main thread. *)
          Eio.Fiber.fork ~sw run_accept_loop
        else
          Eio.Fiber.fork ~sw (fun () ->
            let domain_mgr = Eio.Stdenv.domain_mgr env in
            Eio.Domain_manager.run domain_mgr run_accept_loop)
      done;
      while Eio.Semaphore.get_value started_domains > 0 do
        Fiber.yield ()
      done;
      Logs.info (fun m ->
        m "Server listening on %a" Eio.Net.Sockaddr.pp address);
      { sockets = [ listening_socket ]
      ; shutdown_resolvers = Array.map fst resolvers
      ; client_sockets = Array.map snd resolvers
      ; clock = Eio.Stdenv.clock env
      ; shutdown_timeout
      }

  let start ~sw env server =
    let { config; _ } = server in
    (* TODO(anmonteiro): config option to listen only in HTTPS? *)
    let command =
      let connection_handler = http_connection_handler server in
      listen
        ~sw
        ~address:config.address
        ~backlog:config.backlog
        ~domains:config.domains
        ~shutdown_timeout:config.shutdown_timeout
        ~reuse_addr:config.reuse_addr
        ~reuse_port:config.reuse_port
        env
        connection_handler
    in
    match config.https with
    | None -> command
    | Some https ->
      let clock = Eio.Stdenv.clock env in
      let https_command =
        let connection_handler =
          https_connection_handler ~clock ~https server
        in
        listen
          ~sw
          ~address:https.address
          ~backlog:config.backlog
          ~domains:config.domains
          ~shutdown_timeout:config.shutdown_timeout
          ~reuse_addr:config.reuse_addr
          ~reuse_port:config.reuse_port
          env
          connection_handler
      in
      { sockets = https_command.sockets @ command.sockets
      ; shutdown_resolvers =
          Array.append
            command.shutdown_resolvers
            https_command.shutdown_resolvers
      ; client_sockets =
          Array.append command.client_sockets https_command.client_sockets
      ; clock
      ; shutdown_timeout = config.shutdown_timeout
      }
end
