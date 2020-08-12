open Piaf

let request_handler { Server.request; _ } =
  match Astring.String.cuts ~empty:false ~sep:"/" request.target with
  | [] ->
    Lwt.wrap1 (Response.of_string ~body:request.target) `OK
  | [ "redirect" ] ->
    Lwt.wrap1
      (Response.create ~headers:Headers.(of_list [ Well_known.location, "/" ]))
      `Found
  | "alpn" :: _ ->
    Lwt.wrap1
      (Response.create
         ~headers:
           Headers.(
             of_list
               [ Well_known.location, "https://localhost:9443" ^ request.target
               ; Well_known.connection, "close"
               ]))
      `Moved_permanently
  | _ ->
    assert false

let connection_handler = Server.create request_handler

module HTTP = struct
  let listen port =
    let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
    Lwt_io.establish_server_with_client_socket listen_address connection_handler
end

module ALPN = struct
  open Httpaf

  module Http1_handler = struct
    let request_handler : Unix.sockaddr -> Reqd.t Gluten.reqd -> unit =
     fun _client_address { Gluten.reqd; _ } ->
      let request = Reqd.request reqd in
      let response =
        Response.create
          ~headers:
            (Headers.of_list
               [ ( Piaf.Headers.Well_known.content_length
                 , String.length request.target |> string_of_int )
               ])
          `OK
      in
      Reqd.respond_with_string reqd response request.target

    let error_handler
        :  Unix.sockaddr -> ?request:Request.t -> _
        -> (Headers.t -> [ `write ] Body.t) -> unit
      =
     fun _client_address ?request:_ _error start_response ->
      let response_body = start_response Headers.empty in
      Body.close_writer response_body
  end

  module H2_handler = struct
    open H2

    let request_handler : Unix.sockaddr -> Reqd.t -> unit =
     fun _client_address request_descriptor ->
      let request = Reqd.request request_descriptor in
      let response = Response.create `OK in
      Reqd.respond_with_string request_descriptor response request.target

    let error_handler
        :  Unix.sockaddr -> ?request:H2.Request.t -> _
        -> (Headers.t -> [ `write ] Body.t) -> unit
      =
     fun _client_address ?request:_ _error start_response ->
      let response_body = start_response Headers.empty in
      Body.close_writer response_body
  end

  let http1s_handler =
    Httpaf_lwt_unix.Server.SSL.create_connection_handler
      ?config:None
      ~request_handler:Http1_handler.request_handler
      ~error_handler:Http1_handler.error_handler

  let h2s_handler =
    H2_lwt_unix.Server.SSL.create_connection_handler
      ~request_handler:H2_handler.request_handler
      ~error_handler:H2_handler.error_handler

  let rec first_match l1 = function
    | [] ->
      None
    | x :: _ when List.mem x l1 ->
      Some x
    | _ :: xs ->
      first_match l1 xs

  let https_server port =
    let open Lwt.Infix in
    let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
    let cert = "./certificates/server.pem" in
    let priv_key = "./certificates/server.key" in
    Lwt_io.establish_server_with_client_socket
      listen_address
      (fun client_addr fd ->
        let server_ctx = Ssl.create_context Ssl.TLSv1_3 Ssl.Server_context in
        Ssl.disable_protocols server_ctx [ Ssl.SSLv23; Ssl.TLSv1_1 ];
        Ssl.use_certificate server_ctx cert priv_key;
        let protos = [ "h2"; "http/1.1" ] in
        Ssl.set_context_alpn_protos server_ctx protos;
        Ssl.set_context_alpn_select_callback server_ctx (fun client_protos ->
            first_match client_protos protos);
        Lwt_ssl.ssl_accept fd server_ctx >>= fun ssl_server ->
        match Lwt_ssl.ssl_socket ssl_server with
        | None ->
          Lwt.return_unit
        | Some ssl_socket ->
          (match Ssl.get_negotiated_alpn_protocol ssl_socket with
          | Some "http/1.1" ->
            http1s_handler client_addr ssl_server
          | Some "h2" ->
            h2s_handler client_addr ssl_server
          | None (* Unable to negotiate a protocol *) | Some _ ->
            (* Can't really happen - would mean that TLS negotiated a
             * protocol that we didn't specify. *)
            assert false))
end

type t = Lwt_io.server * Lwt_io.server

let listen ?(http_port = 8080) ?(https_port = 9443) () =
  let http_server = HTTP.listen http_port in
  let https_server = ALPN.https_server https_port in
  Format.eprintf "DUDE@.";
  Lwt.both http_server https_server

let teardown (http, https) =
  Lwt.join [ Lwt_io.shutdown_server http; Lwt_io.shutdown_server https ]
