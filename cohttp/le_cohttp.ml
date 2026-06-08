(* A Cohttp [S.IO] backend on top of Lwt_effects: monadic, non-blocking buffered
   channels over a raw file descriptor (using Lwt_effects' monadic I/O and the
   Compat bind). This lets cohttp's request/response codecs run natively on the
   Lwt_effects scheduler — and hence on io_uring via Lwt_effects_uring — while
   keeping the async type ([_ Lwt_effects.t]). *)

module Make (Eio_like : sig
  (* Monadic, non-blocking fd I/O returning Lwt_effects promises. *)
  val read : Unix.file_descr -> bytes -> int -> int -> int Lwt_effects.t
  val write : Unix.file_descr -> bytes -> int -> int -> int Lwt_effects.t
end) =
struct
  module IO = struct
    type 'a t = 'a Lwt_effects.t

    let ( >>= ) = Lwt_effects.Compat.bind
    let return = Lwt_effects.return

    type ic = {
      fd_in : Unix.file_descr;
      mutable ibuf : bytes;
      mutable ipos : int; (* start of unconsumed data *)
      mutable ilen : int; (* end of valid data *)
    }

    type oc = { fd_out : Unix.file_descr; obuf : Buffer.t }
    type conn = unit

    let make_ic fd = { fd_in = fd; ibuf = Bytes.create 4096; ipos = 0; ilen = 0 }
    let make_oc fd = { fd_out = fd; obuf = Buffer.create 4096 }

    (* Read more bytes into the buffer (compacting first). [`Eof] if the peer
       closed with nothing more to read. *)
    let refill ic : [ `Ok | `Eof ] t =
      if ic.ipos > 0 then begin
        Bytes.blit ic.ibuf ic.ipos ic.ibuf 0 (ic.ilen - ic.ipos);
        ic.ilen <- ic.ilen - ic.ipos;
        ic.ipos <- 0
      end;
      if ic.ilen = Bytes.length ic.ibuf then begin
        let b = Bytes.create (2 * Bytes.length ic.ibuf) in
        Bytes.blit ic.ibuf 0 b 0 ic.ilen;
        ic.ibuf <- b
      end;
      Eio_like.read ic.fd_in ic.ibuf ic.ilen (Bytes.length ic.ibuf - ic.ilen)
      >>= fun n ->
      if n = 0 then return `Eof
      else begin
        ic.ilen <- ic.ilen + n;
        return `Ok
      end

    let with_input_buffer ic ~f =
      let s = Bytes.unsafe_to_string ic.ibuf in
      let result, consumed = f s ~pos:ic.ipos ~len:(ic.ilen - ic.ipos) in
      ic.ipos <- ic.ipos + consumed;
      result

    (* Read a line terminated by LF (stripping a trailing CR). *)
    let rec read_line ic : string option t =
      let rec find i = if i >= ic.ilen then -1 else if Bytes.get ic.ibuf i = '\n' then i else find (i + 1) in
      match find ic.ipos with
      | -1 -> (
        refill ic >>= function
        | `Ok -> read_line ic
        | `Eof ->
          if ic.ilen > ic.ipos then begin
            let s = Bytes.sub_string ic.ibuf ic.ipos (ic.ilen - ic.ipos) in
            ic.ipos <- ic.ilen;
            return (Some s)
          end
          else return None)
      | nl ->
        let stop = if nl > ic.ipos && Bytes.get ic.ibuf (nl - 1) = '\r' then nl - 1 else nl in
        let s = Bytes.sub_string ic.ibuf ic.ipos (stop - ic.ipos) in
        ic.ipos <- nl + 1;
        return (Some s)

    let rec read ic len : string t =
      if ic.ipos >= ic.ilen then
        refill ic >>= function `Eof -> return "" | `Ok -> read ic len
      else begin
        let n = min len (ic.ilen - ic.ipos) in
        let s = Bytes.sub_string ic.ibuf ic.ipos n in
        ic.ipos <- ic.ipos + n;
        return s
      end

    let write oc s =
      Buffer.add_string oc.obuf s;
      return ()

    let flush oc : unit t =
      let s = Buffer.to_bytes oc.obuf in
      Buffer.clear oc.obuf;
      let len = Bytes.length s in
      let rec loop off =
        if off >= len then return ()
        else Eio_like.write oc.fd_out s off (len - off) >>= fun n -> loop (off + n)
      in
      loop 0
  end

  module Request = Cohttp.Request.Private.Make (IO)
  module Response = Cohttp.Response.Private.Make (IO)
end
